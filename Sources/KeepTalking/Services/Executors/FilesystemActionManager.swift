import Foundation
import MCP

/// Bridge that lets `FilesystemActionManager` stream a host file back to the
/// caller as a one-time encrypted blob (OTB). Replaces the old context-attachment
/// bridge: transfers are point-to-point and ephemeral, never published to the
/// conversation, never recorded.
public struct FilesystemTransferBridge: Sendable {
    /// Streams `fileURL` to `recipient` as a one-time encrypted blob and returns
    /// the ref (with the sealed key) to embed in the action result.
    public let sendOneTimeBlob:
        @Sendable (
            _ fileURL: URL, _ filename: String, _ mimeType: String, _ recipient: UUID
        ) async throws -> KeepTalkingOneTimeBlobRef

    /// Creates a bridge around the closure that performs the transfer.
    ///
    /// - Parameter sendOneTimeBlob: Streams the file at `fileURL` to `recipient`
    ///   as a one-time encrypted blob, tagging it with `filename` and
    ///   `mimeType`, and returns the ref (with the sealed key) to embed in the
    ///   action result.
    public init(
        sendOneTimeBlob:
            @escaping @Sendable (
                _ fileURL: URL, _ filename: String, _ mimeType: String, _ recipient: UUID
            ) async throws -> KeepTalkingOneTimeBlobRef
    ) {
        self.sendOneTimeBlob = sendOneTimeBlob
    }
}

/// Reference-type holder that lets `KeepTalkingClient` inject the bridge after its own init
/// completes (avoiding a use-before-initialized error on `self`).
final class FilesystemTransferBridgeBox: @unchecked Sendable {
    var bridge: FilesystemTransferBridge?
    init() {}
}

public enum FilesystemActionManagerError: LocalizedError {
    case invalidAction
    case missingActionID
    case operationDenied(KeepTalkingFilesystemOperation)
    case pathOutsideRoot(String)
    case invalidArguments(String)
    case sandboxNotConfigured
    case blobBridgeNotConfigured
    case contextRequired
    case blobNotAvailable(String)

    public var errorDescription: String? {
        switch self {
            case .invalidAction:
                return "Action payload is not a filesystem bundle."
            case .missingActionID:
                return "Action must have an ID before registration."
            case .operationDenied(let op):
                return "Operation '\(op.rawValue)' is not permitted by the grant scope."
            case .pathOutsideRoot(let path):
                return "Path '\(path)' is outside the permitted root."
            case .invalidArguments(let detail):
                return "Invalid filesystem arguments: \(detail)"
            case .sandboxNotConfigured:
                return "Filesystem root path is not configured."
            case .blobBridgeNotConfigured:
                return "Blob bridge is not configured; blob transfer operations are unavailable."
            case .contextRequired:
                return "Context not found for the given context ID."
            case .blobNotAvailable(let blobID):
                return "Blob '\(blobID)' is not available locally (missing or still transferring)."
        }
    }
}

/// Handles execution of filesystem action calls with mask-based access control.
///
/// The manager operates entirely within the SDK; no user callback is required.
/// At execution time it:
/// 1. Verifies the requested operation is permitted by the caller's grant mask.
/// 2. Resolves and validates the target path against the bundle's `rootPath` sandbox.
/// 3. Executes the operation and returns tool content.
///
/// The binary transfer op `get-file` (streaming a host file to a remote caller)
/// requires a `FilesystemTransferBridge` populated on `bridgeBox`; all other ops
/// (including local-execution get/put-file) work without it.
public actor FilesystemActionManager {
    private var bundlesByActionID: [UUID: KeepTalkingFilesystemBundle] = [:]
    /// Populated by `KeepTalkingClient` synchronously after its own init completes.
    let bridgeBox = FilesystemTransferBridgeBox()

    private var transferBridge: FilesystemTransferBridge? { bridgeBox.bridge }

    public init() {}

    /// Caches an action's filesystem bundle so later calls can resolve its
    /// `rootPath` sandbox.
    ///
    /// - Parameter action: An action whose payload is a filesystem bundle.
    /// - Throws: `FilesystemActionManagerError.invalidAction` if the payload is
    ///   not a filesystem bundle, or `.missingActionID` if the action has no ID.
    public func registerFilesystemAction(_ action: KeepTalkingAction) async throws {
        guard case .filesystem(let bundle) = action.payload else {
            throw FilesystemActionManagerError.invalidAction
        }
        guard let actionID = action.id else {
            throw FilesystemActionManagerError.missingActionID
        }
        bundlesByActionID[actionID] = bundle
    }

    public func refreshFilesystemAction(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw FilesystemActionManagerError.missingActionID
        }
        bundlesByActionID.removeValue(forKey: actionID)
        try await registerFilesystemAction(action)
    }

    public func unregisterAction(actionID: UUID) async {
        bundlesByActionID.removeValue(forKey: actionID)
    }

    public func registerIfNeeded(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw FilesystemActionManagerError.missingActionID
        }
        if bundlesByActionID[actionID] == nil {
            try await registerFilesystemAction(action)
        }
    }

    /// Returns the filesystem tools visible to a caller given their grant scope.
    public func availableTools(
        bundle: KeepTalkingFilesystemBundle,
        scope: KeepTalkingActionScope
    ) -> [KeepTalkingFilesystemTool] {
        KeepTalkingFilesystemOperation.allCases
            .filter { scope.allows($0.requiredVerb) }
            .map { KeepTalkingFilesystemTool(operation: $0, description: $0.toolDescription) }
    }

    /// Executes a filesystem action call, enforcing the caller's grant mask.
    ///
    /// - Parameters:
    ///   - action: The action being called.
    ///   - call: The call payload containing `operation` and arguments.
    ///   - scope: Effective grant scope from the caller's grant.
    ///   - contextID: The active context's UUID.
    ///   - callerNodeID: Node that issued the call. Used as the recipient when
    ///     `get-file` streams a host file back as a one-time encrypted blob.
    ///   - isLocalExecution: `true` when the caller is this node and therefore
    ///     already has filesystem access. `get-file` then reports the resolved
    ///     host path instead of streaming a blob, and `put-file` reads its bytes
    ///     from the caller-supplied `source` argument instead of `inputFiles`.
    ///   - inputFiles: Files the controller materialized from the call's
    ///     one-time blob transfers. Only consulted for a remote `put-file`,
    ///     which uses the first entry as its source; ignored for every other
    ///     operation and for local execution.
    /// - Returns: The operation's text content, an `isError` flag (always
    ///   `false` — failures are thrown rather than reported), and any one-time
    ///   blob refs the operation produced. `outputTransfers` is non-empty only
    ///   for a remote `get-file`.
    public func callAction(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall,
        scope: KeepTalkingActionScope,
        contextID: UUID,
        callerNodeID: UUID,
        isLocalExecution: Bool,
        inputFiles: [URL] = []
    ) async throws -> (
        content: [Tool.Content], isError: Bool?,
        outputTransfers: [KeepTalkingOneTimeBlobRef]
    ) {
        guard case .filesystem(let bundle) = action.payload else {
            throw FilesystemActionManagerError.invalidAction
        }
        try await registerIfNeeded(action)

        // Resolve operation name: proxy wrapper puts it in "tool", direct calls may use "operation".
        let opString: String
        let callArguments: [String: Value]
        if case .string(let tool) = call.arguments["tool"] {
            opString = tool
            if let nested = call.arguments["arguments"]?.objectValue {
                callArguments = nested
            } else {
                var passthrough = call.arguments
                passthrough.removeValue(forKey: "tool")
                callArguments = passthrough
            }
        } else if case .string(let op) = call.arguments["operation"] {
            opString = op
            callArguments = call.arguments
        } else {
            throw FilesystemActionManagerError.invalidArguments(
                "Missing operation: supply 'tool' or 'operation' argument."
            )
        }

        guard let operation = KeepTalkingFilesystemOperation(rawValue: opString) else {
            throw FilesystemActionManagerError.invalidArguments(
                "Unknown filesystem operation '\(opString)'."
            )
        }

        guard scope.allows(operation.requiredVerb) else {
            throw FilesystemActionManagerError.operationDenied(operation)
        }

        let result = try await execute(
            operation: operation,
            arguments: callArguments,
            rootPath: bundle.rootPath,
            contextID: contextID,
            callerNodeID: callerNodeID,
            isLocalExecution: isLocalExecution,
            inputFiles: inputFiles
        )
        return (
            content: [.text(text: result.text, annotations: nil, _meta: nil)],
            isError: false,
            outputTransfers: result.outputTransfers
        )
    }

    // MARK: - Private execution

    private func execute(
        operation: KeepTalkingFilesystemOperation,
        arguments: [String: Value],
        rootPath: String,
        contextID: UUID,
        callerNodeID: UUID,
        isLocalExecution: Bool,
        inputFiles: [URL]
    ) async throws -> (text: String, outputTransfers: [KeepTalkingOneTimeBlobRef]) {
        switch operation {
            case .ls:
                let resolved = try resolvedPath(
                    try requiredStringArg("path", from: arguments), root: rootPath)
                return (try listDirectory(at: resolved), [])

            case .readFile:
                let resolved = try resolvedPath(
                    try requiredStringArg("path", from: arguments), root: rootPath)
                return (try readFile(at: resolved), [])

            case .grep:
                let pattern = try requiredStringArg("pattern", from: arguments)
                let resolved = try resolvedPath(
                    try requiredStringArg("path", from: arguments), root: rootPath)
                return (try grepFiles(pattern: pattern, at: resolved), [])

            case .sed:
                let resolved = try resolvedPath(
                    try requiredStringArg("path", from: arguments), root: rootPath)
                return (
                    try applySed(
                        pattern: try requiredStringArg("pattern", from: arguments),
                        replacement: try requiredStringArg(
                            "replacement", from: arguments),
                        flags: arguments["flags"]?.stringValue ?? "",
                        at: resolved
                    ),
                    []
                )

            case .writeFile:
                let content = try requiredStringArg("content", from: arguments)
                let resolved = try resolvedPath(
                    try requiredStringArg("path", from: arguments), root: rootPath)
                try writeFile(content: content, at: resolved)
                return ("Written \(content.utf8.count) bytes to \(resolved).", [])

            case .stat:
                let resolved = try resolvedPath(
                    try requiredStringArg("path", from: arguments), root: rootPath)
                return (try statPath(at: resolved), [])

            case .getFile:
                let resolved = try resolvedPath(
                    try requiredStringArg("path", from: arguments), root: rootPath)
                let fileURL = URL(fileURLWithPath: resolved)
                guard FileManager.default.fileExists(atPath: resolved) else {
                    throw FilesystemActionManagerError.invalidArguments(
                        "No file at '\(resolved)'.")
                }
                let filename = fileURL.lastPathComponent
                let mimeType = mimeTypeForPath(resolved)
                // Local caller already has filesystem access — no transfer needed.
                if isLocalExecution {
                    return ("File available locally at \(resolved) (mime_type=\(mimeType)).", [])
                }
                guard let bridge = transferBridge else {
                    throw FilesystemActionManagerError.blobBridgeNotConfigured
                }
                let ref = try await bridge.sendOneTimeBlob(
                    fileURL, filename, mimeType, callerNodeID)
                return (
                    "Streaming \(filename) (\(ref.byteCount) bytes) back as a one-time encrypted transfer.",
                    [ref]
                )

            case .putFile:
                let resolved = try resolvedPath(
                    try requiredStringArg("path", from: arguments), root: rootPath)
                let source: URL
                if isLocalExecution {
                    // Local caller supplies a source path it can already read.
                    let src = try requiredStringArg("source", from: arguments)
                    source = URL(fileURLWithPath: (src as NSString).expandingTildeInPath)
                } else {
                    // Remote caller streamed the bytes; controller materialized them.
                    guard let input = inputFiles.first else {
                        throw FilesystemActionManagerError.invalidArguments(
                            "put-file requires a streamed input file.")
                    }
                    source = input
                }
                let data = try Data(contentsOf: source)
                let destination = URL(fileURLWithPath: resolved)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: destination)
                return ("Wrote \(data.count) bytes to \(resolved).", [])
        }
    }

    /// Applies a regular-expression substitution to an entire UTF-8 file.
    private func applySed(
        pattern: String,
        replacement: String,
        flags: String,
        at path: String
    ) throws -> String {
        let unsupportedFlags = Set(flags).subtracting("gims")
        guard unsupportedFlags.isEmpty else {
            throw FilesystemActionManagerError.invalidArguments(
                "Unsupported sed flag(s): \(String(unsupportedFlags.sorted())).")
        }
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        let regex = try NSRegularExpression(pattern: pattern, options: options)

        guard let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8)
        else {
            throw FilesystemActionManagerError.invalidArguments(
                "Cannot read '\(path)' as UTF-8 text.")
        }
        // sed uses \1 for capture groups; NSRegularExpression templates use $1.
        // sed backref `\1` → NSRegularExpression template `$1`. The replacement
        // string is itself a template under .regularExpression, so `$$`→`$` and
        // `$1`→search-group-1 (the digit); we want a literal backslash-escaped
        // `$` followed by the digit, i.e. `\$$1` → emits `$1`.
        let template = replacement.replacingOccurrences(
            of: #"\\(\d)"#, with: #"\$$1"#, options: .regularExpression)

        let fullRange = NSRange(text.startIndex..., in: text)
        let result: String
        let count: Int
        if flags.contains("g") {
            count = regex.numberOfMatches(in: text, range: fullRange)
            result = regex.stringByReplacingMatches(
                in: text, range: fullRange, withTemplate: template)
        } else if let first = regex.firstMatch(in: text, range: fullRange) {
            let mutable = NSMutableString(string: text)
            regex.replaceMatches(in: mutable, range: first.range, withTemplate: template)
            result = mutable as String
            count = 1
        } else {
            result = text
            count = 0
        }

        guard let outData = result.data(using: .utf8) else {
            throw FilesystemActionManagerError.invalidArguments(
                "Result is not encodable as UTF-8.")
        }
        try outData.write(to: URL(fileURLWithPath: path))
        return "sed applied to \(path): \(count) replacement(s)."
    }

    private func requiredStringArg(
        _ key: String,
        from args: [String: Value]
    ) throws -> String {
        guard let v = args[key], case .string(let s) = v else {
            throw FilesystemActionManagerError.invalidArguments(
                "Missing required string argument '\(key)'."
            )
        }
        return s
    }

    /// Resolves a caller-supplied path STRICTLY RELATIVE to the action's
    /// `rootPath`. Leading slashes are stripped so "", "/", and "." all mean the
    /// root itself, and an absolute-looking argument is interpreted relative to
    /// the root — never the host filesystem. `..` (or any escape) is rejected by
    /// the containment check after standardization. An empty root fails closed.
    private func resolvedPath(_ path: String, root: String) throws -> String {
        let rootExpanded = (root as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootExpanded.isEmpty else {
            throw FilesystemActionManagerError.sandboxNotConfigured
        }
        let rootURL = URL(fileURLWithPath: rootExpanded).standardizedFileURL
        let rootResolved = rootURL.path

        var relative = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while relative.hasPrefix("/") { relative.removeFirst() }
        let candidate = relative.isEmpty ? rootURL : rootURL.appendingPathComponent(relative)
        let resolved = candidate.standardizedFileURL.path

        // Boundary on a path separator so a sibling like `<root>-secrets` can't
        // satisfy a bare prefix check and escape the sandbox.
        let rootWithSep = rootResolved.hasSuffix("/") ? rootResolved : rootResolved + "/"
        guard resolved == rootResolved || resolved.hasPrefix(rootWithSep) else {
            throw FilesystemActionManagerError.pathOutsideRoot(path)
        }

        // The lexical check above can't see a symlink that lives INSIDE the root
        // but points outside it. Resolve symlinks on both sides and re-verify, so
        // an in-root symlink can't be used to read/write outside the sandbox.
        // (Matches SkillManager+ToolCalls' containment.)
        let realRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let realResolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let realRootWithSep = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        guard realResolved == realRoot || realResolved.hasPrefix(realRootWithSep) else {
            throw FilesystemActionManagerError.pathOutsideRoot(path)
        }
        return resolved
    }

    private func listDirectory(at path: String) throws -> String {
        let items = try FileManager.default.contentsOfDirectory(atPath: path)
        return items.sorted().joined(separator: "\n")
    }

    private func readFile(at path: String) throws -> String {
        guard let content = FileManager.default.contents(atPath: path),
            let text = String(data: content, encoding: .utf8)
        else {
            throw FilesystemActionManagerError.invalidArguments(
                "Cannot read '\(path)' as UTF-8 text."
            )
        }
        return text
    }

    private func grepFiles(pattern: String, at path: String) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        var results: [String] = []
        let fm = FileManager.default

        func search(_ filePath: String) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: filePath, isDirectory: &isDir) else { return }
            if isDir.boolValue {
                let children = (try? fm.contentsOfDirectory(atPath: filePath)) ?? []
                for child in children {
                    search((filePath as NSString).appendingPathComponent(child))
                }
            } else {
                guard
                    let data = fm.contents(atPath: filePath),
                    let text = String(data: data, encoding: .utf8)
                else { return }
                let lines = text.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() {
                    let range = NSRange(line.startIndex..., in: line)
                    if regex.firstMatch(in: line, range: range) != nil {
                        results.append("\(filePath):\(i + 1):\(line)")
                    }
                }
            }
        }

        search(path)
        return results.isEmpty ? "(no matches)" : results.joined(separator: "\n")
    }

    private func writeFile(content: String, at path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = content.data(using: .utf8) else {
            throw FilesystemActionManagerError.invalidArguments(
                "Content cannot be encoded as UTF-8."
            )
        }
        try data.write(to: url)
    }

    private func statPath(at path: String) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let type = attrs[.type] as? String ?? "unknown"
        let size = attrs[.size] as? Int ?? 0
        let modified = attrs[.modificationDate] as? Date
        let modString =
            modified.map {
                ISO8601DateFormatter().string(from: $0)
            } ?? "unknown"
        return "type=\(type) size=\(size) modified=\(modString)"
    }

    private func mimeTypeForPath(_ path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension
        if !ext.isEmpty, let mime = MIMEType.preferredMIMEType(forExtension: ext) {
            return mime
        }
        return "application/octet-stream"
    }
}
