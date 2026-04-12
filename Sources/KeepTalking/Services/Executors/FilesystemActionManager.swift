import Foundation
import MCP

public enum FilesystemActionManagerError: LocalizedError {
    case invalidAction
    case missingActionID
    case operationDeniedByMask(KeepTalkingFilesystemOperation)
    case pathOutsideRoot(String)
    case invalidArguments(String)
    case sandboxNotConfigured

    public var errorDescription: String? {
        switch self {
        case .invalidAction:
            return "Action payload is not a filesystem bundle."
        case .missingActionID:
            return "Action must have an ID before registration."
        case .operationDeniedByMask(let op):
            return "Operation '\(op.rawValue)' is not permitted by the grant mask."
        case .pathOutsideRoot(let path):
            return "Path '\(path)' is outside the permitted root."
        case .invalidArguments(let detail):
            return "Invalid filesystem arguments: \(detail)"
        case .sandboxNotConfigured:
            return "Filesystem root path is not configured."
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
public actor FilesystemActionManager {
    private var bundlesByActionID: [UUID: KeepTalkingFilesystemBundle] = [:]

    public init() {}

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

    /// Returns the filesystem tools visible to a caller given their grant mask.
    public func availableTools(
        bundle: KeepTalkingFilesystemBundle,
        mask: KeepTalkingActionPermissionMask
    ) -> [KeepTalkingFilesystemTool] {
        KeepTalkingFilesystemOperation.allCases
            .filter { mask.contains($0.requiredMask) }
            .map { KeepTalkingFilesystemTool(operation: $0, description: $0.toolDescription) }
    }

    /// Executes a filesystem action call, enforcing the caller's grant mask.
    ///
    /// - Parameters:
    ///   - action: The action being called.
    ///   - call: The call payload containing `operation` and arguments.
    ///   - callerMask: Effective permission mask from the caller's grant.
    public func callAction(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall,
        callerMask: KeepTalkingActionPermissionMask
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
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

        guard callerMask.contains(operation.requiredMask) else {
            throw FilesystemActionManagerError.operationDeniedByMask(operation)
        }

        let output = try await execute(
            operation: operation,
            arguments: callArguments,
            rootPath: bundle.rootPath
        )
        return (
            content: [.text(text: output, annotations: nil, _meta: nil)],
            isError: false
        )
    }

    // MARK: - Private execution

    private func execute(
        operation: KeepTalkingFilesystemOperation,
        arguments: [String: Value],
        rootPath: String?
    ) async throws -> String {
        switch operation {
        case .ls:
            let path = try requiredStringArg("path", from: arguments)
            let resolved = try resolvedPath(path, root: rootPath)
            return try listDirectory(at: resolved)

        case .readFile:
            let path = try requiredStringArg("path", from: arguments)
            let resolved = try resolvedPath(path, root: rootPath)
            return try readFile(at: resolved)

        case .grep:
            let pattern = try requiredStringArg("pattern", from: arguments)
            let path = try requiredStringArg("path", from: arguments)
            let resolved = try resolvedPath(path, root: rootPath)
            return try grepFiles(pattern: pattern, at: resolved)

        case .writeFile:
            let path = try requiredStringArg("path", from: arguments)
            let content = try requiredStringArg("content", from: arguments)
            let resolved = try resolvedPath(path, root: rootPath)
            try writeFile(content: content, at: resolved)
            return "Written \(content.utf8.count) bytes to \(resolved)."

        case .stat:
            let path = try requiredStringArg("path", from: arguments)
            let resolved = try resolvedPath(path, root: rootPath)
            return try statPath(at: resolved)
        }
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

    private func resolvedPath(
        _ path: String,
        root: String?
    ) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).standardized.path

        if let root {
            let rootExpanded = (root as NSString).expandingTildeInPath
            let rootResolved = URL(fileURLWithPath: rootExpanded).standardized.path
            guard resolved.hasPrefix(rootResolved) else {
                throw FilesystemActionManagerError.pathOutsideRoot(path)
            }
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
        let modString = modified.map {
            ISO8601DateFormatter().string(from: $0)
        } ?? "unknown"
        return "type=\(type) size=\(size) modified=\(modString)"
    }
}
