#if os(macOS)
import Foundation
import Logging
import MCP

public enum ACPManagerError: LocalizedError {
    case invalidAction
    case missingActionID
    case emptyCommand
    case launcherUnavailable
    case missingPrompt
    case sessionFailed(String)
    case agentError(code: Int, message: String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
            case .invalidAction:
                return "Action payload is not an ACP bundle."
            case .missingActionID:
                return "Action must have an ID before registration."
            case .emptyCommand:
                return "ACP bundle has no agent command to launch."
            case .launcherUnavailable:
                return "Subprocess launching is unavailable on this platform."
            case .missingPrompt:
                return "ACP action call is missing a `prompt` argument."
            case .sessionFailed(let detail):
                return "ACP session failed: \(detail)"
            case .agentError(let code, let message):
                return "ACP agent error (\(code)): \(message)"
            case .timedOut(let what):
                return "ACP timed out: \(what)"
        }
    }
}

/// Drives external Agent Client Protocol (ACP) agents as a CLIENT: spawns the
/// agent as a stdio subprocess, speaks JSON-RPC 2.0, runs one prompt turn, and
/// returns the agent's final message.
///
/// ACP enforces no containment of its own, and — by design — neither does KT:
/// the agent subprocess runs UNsandboxed (like stdio MCP). Containment is
/// ADVISORY, surfaced to a well-behaved agent rather than enforced on the
/// process. For hard isolation, run the agent in a container/VM and point the
/// ACP action at it. The granted `KeepTalkingActionScope` shapes the advice:
/// - the cwd is passed via `session/new` as the recommended working root;
/// - advertised `fs.*` capabilities derive from the scope (a read-only grant
///   recommends read-only), and when the agent routes a file op THROUGH KT, the
///   KT-served `fs/read_text_file` / `fs/write_text_file` is scope-gated and
///   path-contained to cwd + additionalDirectories (KT won't proxy arbitrary
///   paths — though the agent can still touch the disk directly, unsandboxed);
/// - `session/request_permission` is auto-resolved against the scope.
///
/// v1 is spawn-per-call (a fresh session per prompt) and returns the agent's
/// final text as the tool result; live `session/update` streaming into the
/// conversation is a future enhancement. macOS-only.
public actor ACPManager {
    /// ACP protocol version this client implements.
    static let protocolVersion = 1
    /// How long to wait for any single JSON-RPC request (initialize/session.*).
    private let requestTimeoutSeconds: TimeInterval
    /// How long to wait for the whole prompt turn before giving up.
    private let promptTimeoutSeconds: TimeInterval

    private let nodeConfig: KeepTalkingConfig
    private let stdioTransportLauncher: (any MCPStdioTransportLaunching)?
    private var bundlesByActionID: [UUID: KeepTalkingACPBundle] = [:]
    private var onLog: (@Sendable (String) -> Void)?

    public init(
        nodeConfig: KeepTalkingConfig,
        stdioTransportLauncher: (any MCPStdioTransportLaunching)? =
            DefaultMCPStdioTransportLauncher.current,
        requestTimeoutSeconds: TimeInterval = 30,
        promptTimeoutSeconds: TimeInterval = 600
    ) {
        self.nodeConfig = nodeConfig
        self.stdioTransportLauncher = stdioTransportLauncher
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.promptTimeoutSeconds = promptTimeoutSeconds
    }

    public func setLogHandler(_ handler: (@Sendable (String) -> Void)?) {
        onLog = handler
    }

    // MARK: - Registration (spawn-per-call; tracking only)

    public func registerACPAction(_ action: KeepTalkingAction) async throws {
        guard case .acp(let bundle) = action.payload else {
            throw ACPManagerError.invalidAction
        }
        guard let actionID = action.id else {
            throw ACPManagerError.missingActionID
        }
        bundlesByActionID[actionID] = bundle
    }

    public func refreshACPAction(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw ACPManagerError.missingActionID
        }
        bundlesByActionID.removeValue(forKey: actionID)
        try await registerACPAction(action)
    }

    public func unregisterAction(actionID: UUID) async {
        bundlesByActionID.removeValue(forKey: actionID)
    }

    public func disableAction(actionID: UUID) async {
        bundlesByActionID.removeValue(forKey: actionID)
    }

    public func registerIfNeeded(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw ACPManagerError.missingActionID
        }
        if bundlesByActionID[actionID] == nil {
            try await registerACPAction(action)
        }
    }

    // MARK: - Execution

    /// Runs one ACP prompt turn and returns the agent's final message text.
    ///
    /// The agent subprocess runs UNsandboxed by design (see the type doc); the
    /// `scope` only shapes advisory containment — the advertised fs capabilities,
    /// the KT-served fs path-containment, and the permission auto-policy.
    ///
    /// - Parameter callerIsRemote: when `true` and the bundle defines a
    ///   `remoteSystemPrompt`, that text is injected ahead of the prompt as the
    ///   owner's manual limitation on remote use. Local/owner calls are unconstrained.
    public func callAction(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall,
        scope: KeepTalkingActionScope,
        callerIsRemote: Bool
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        guard case .acp(let bundle) = action.payload else {
            throw ACPManagerError.invalidAction
        }
        guard !bundle.command.isEmpty else {
            throw ACPManagerError.emptyCommand
        }
        guard let launcher = stdioTransportLauncher else {
            throw ACPManagerError.launcherUnavailable
        }
        guard let prompt = call.arguments["prompt"]?.stringValue,
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ACPManagerError.missingPrompt
        }

        let actionLabel = action.id?.uuidString.lowercased() ?? "unknown"
        let log = onLog
        log?("[acp] launching agent action=\(actionLabel) cmd=\(bundle.command.first ?? "?")")

        let launched = try await launcher.launchTransport(
            command: bundle.command,
            environment: bundle.environment,
            stderrHandler: { data in
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
                    log?("[acp/stderr] action=\(actionLabel) \(line)")
                }
            },
            // Advisory containment only: the agent runs unsandboxed (like stdio
            // MCP). Use a container/VM for hard isolation.
            sandboxPolicy: nil
        )

        let roots = ([bundle.cwd] + bundle.additionalDirectories).map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
        }
        let session = ACPSession(
            transport: launched.transport,
            scope: scope,
            roots: roots,
            onLog: log
        )

        func teardown() async {
            await session.stop()
            launched.processHandler.terminate()
        }

        do {
            try await session.start()
            try await withTimeout(requestTimeoutSeconds, label: "initialize") {
                try await session.initialize(
                    clientName: "KeepTalking:\(self.nodeConfig.node.uuidString)",
                    protocolVersion: Self.protocolVersion,
                    fsRead: scope.allows(.read),
                    fsWrite: scope.allows(.write)
                )
            }
            let sessionID = try await withTimeout(requestTimeoutSeconds, label: "session/new") {
                try await session.newSession(cwd: bundle.cwd.path)
            }
            // Owner's manual limitation for remote callers — injected ahead of the
            // prompt. Local/owner calls are unconstrained.
            let systemPreamble: String? = {
                guard callerIsRemote,
                    let extra = bundle.remoteSystemPrompt?.trimmingCharacters(
                        in: .whitespacesAndNewlines),
                    !extra.isEmpty
                else { return nil }
                return "The following constraints are set by the host operator and MUST be respected:\n\(extra)"
            }()
            try await withTimeout(promptTimeoutSeconds, label: "session/prompt") {
                try await session.prompt(
                    sessionID: sessionID, text: prompt, systemPreamble: systemPreamble)
            }
            let text = await session.collectedText()
            await teardown()
            log?("[acp] action=\(actionLabel) completed (\(text.count) chars)")
            let body = text.isEmpty ? "(agent returned no text)" : text
            return (content: [.text(text: body, annotations: nil, _meta: nil)], isError: false)
        } catch {
            await teardown()
            log?("[acp] action=\(actionLabel) failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Races an operation against a timeout, throwing `ACPManagerError.timedOut`.
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        label: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ACPManagerError.timedOut(label)
            }
            guard let result = try await group.next() else {
                throw ACPManagerError.timedOut(label)
            }
            group.cancelAll()
            return result
        }
    }
}

/// A minimal JSON-RPC 2.0 peer over an ACP stdio transport. Hand-rolled (not the
/// MCP `Client`, whose methods are MCP-specific) because ACP is bidirectional and
/// uses its own `session/*`, `fs/*` methods. Messages are newline-framed by the
/// underlying `MCPPipeTransport`.
private actor ACPSession {
    private let transport: any Transport
    private let scope: KeepTalkingActionScope
    /// Symlink-resolved absolute root paths fs operations are contained to.
    private let roots: [String]
    private let onLog: (@Sendable (String) -> Void)?

    private var nextRequestID = 1
    // Continuations carry the raw response `Data` (Sendable) — never `[String: Any]`
    // (non-Sendable) — and `request` decodes the result after resuming.
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var sessionID: String?
    /// Tool-call kinds learned from `tool_call` notifications, keyed by id —
    /// used to scope-gate the matching `session/request_permission`.
    private var toolKindByID: [String: String] = [:]
    private var agentText = ""

    init(
        transport: any Transport,
        scope: KeepTalkingActionScope,
        roots: [String],
        onLog: (@Sendable (String) -> Void)?
    ) {
        self.transport = transport
        self.scope = scope
        self.roots = roots
        self.onLog = onLog
    }

    func start() async throws {
        try await transport.connect()
        let stream = await transport.receive()
        readTask = Task { [weak self] in
            do {
                for try await data in stream {
                    await self?.handleIncoming(data)
                }
            } catch {
                await self?.failAll(error)
            }
            await self?.failAll(ACPManagerError.sessionFailed("transport closed"))
        }
    }

    func stop() async {
        readTask?.cancel()
        readTask = nil
        await transport.disconnect()
        failAll(ACPManagerError.sessionFailed("session stopped"))
    }

    func collectedText() -> String { agentText }

    // MARK: Outgoing requests

    func initialize(
        clientName: String,
        protocolVersion: Int,
        fsRead: Bool,
        fsWrite: Bool
    ) async throws {
        _ = try await request(
            method: "initialize",
            params: [
                "protocolVersion": protocolVersion,
                "clientCapabilities": [
                    "fs": ["readTextFile": fsRead, "writeTextFile": fsWrite],
                    // Terminal is not bridged in v1; the sandbox confines any
                    // direct command execution the agent performs instead.
                    "terminal": false,
                ],
                "clientInfo": [
                    "name": clientName, "title": "KeepTalking", "version": "1.0.0",
                ],
            ]
        )
    }

    func newSession(cwd: String) async throws -> String {
        let result = try await request(
            method: "session/new",
            params: ["cwd": cwd, "mcpServers": [Any]()]
        )
        guard let id = result["sessionId"] as? String else {
            throw ACPManagerError.sessionFailed("session/new returned no sessionId")
        }
        sessionID = id
        return id
    }

    func prompt(sessionID: String, text: String, systemPreamble: String?) async throws {
        var blocks: [[String: Any]] = []
        if let systemPreamble, !systemPreamble.isEmpty {
            blocks.append(["type": "text", "text": systemPreamble])
        }
        blocks.append(["type": "text", "text": text])
        _ = try await request(
            method: "session/prompt",
            params: ["sessionId": sessionID, "prompt": blocks]
        )
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message)
        } catch {
            throw ACPManagerError.sessionFailed("encode \(method): \(error.localizedDescription)")
        }
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self, transport] in
                do { try await transport.send(data) } catch {
                    await self?.failRequest(id, error)
                }
            }
        }
        let object = try? JSONSerialization.jsonObject(with: responseData)
        return (object as? [String: Any])?["result"] as? [String: Any] ?? [:]
    }

    private func failRequest(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        let conts = pending
        pending.removeAll()
        for (_, cont) in conts { cont.resume(throwing: error) }
    }

    // MARK: Incoming dispatch

    private func handleIncoming(_ data: Data) async {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let message = object as? [String: Any]
        else { return }

        let method = message["method"] as? String
        let hasID = message["id"] != nil

        if let method, hasID {
            await handleAgentRequest(method: method, id: message["id"]!, message: message)
            return
        }
        if let method {
            handleNotification(method: method, message: message)
            return
        }
        if hasID, let intID = (message["id"] as? NSNumber)?.intValue ?? (message["id"] as? Int) {
            handleResponse(id: intID, message: message, raw: data)
        }
    }

    private func handleResponse(id: Int, message: [String: Any], raw: Data) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? (error["code"] as? Int) ?? -1
            let msg = error["message"] as? String ?? "unknown error"
            continuation.resume(throwing: ACPManagerError.agentError(code: code, message: msg))
            return
        }
        // Resume with the raw bytes (Sendable); `request` decodes the result dict.
        continuation.resume(returning: raw)
    }

    private func handleNotification(method: String, message: [String: Any]) {
        guard method == "session/update",
            let params = message["params"] as? [String: Any],
            let update = params["update"] as? [String: Any],
            let kind = update["sessionUpdate"] as? String
        else { return }

        switch kind {
            case "agent_message_chunk":
                if let content = update["content"] as? [String: Any],
                    let text = content["text"] as? String
                {
                    agentText += text
                }
            case "tool_call":
                if let toolCallID = update["toolCallId"] as? String,
                    let toolKind = update["kind"] as? String
                {
                    toolKindByID[toolCallID] = toolKind
                }
            default:
                break
        }
    }

    // MARK: Incoming agent→client requests

    private func handleAgentRequest(method: String, id: Any, message: [String: Any]) async {
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
            case "session/request_permission":
                respondPermission(id: id, params: params)
            case "fs/read_text_file":
                respondReadFile(id: id, params: params)
            case "fs/write_text_file":
                respondWriteFile(id: id, params: params)
            default:
                // Unknown / unsupported (e.g. terminal/*): method-not-found.
                sendError(id: id, code: -32601, message: "Method not supported: \(method)")
        }
    }

    /// Auto-resolve permission against the granted scope. Picks the matching
    /// `allow_once`/`reject_once` option from the offered set.
    private func respondPermission(id: Any, params: [String: Any]) {
        let toolCall = params["toolCall"] as? [String: Any]
        let toolCallID = toolCall?["toolCallId"] as? String
        let toolKind = toolCallID.flatMap { toolKindByID[$0] }
        let allowed = permits(toolKind: toolKind)
        let wantKind = allowed ? "allow_once" : "reject_once"
        let options = params["options"] as? [[String: Any]] ?? []
        let optionID =
            options.first(where: { ($0["kind"] as? String) == wantKind })?["optionId"] as? String
            ?? options.first(where: {
                let k = $0["kind"] as? String
                return allowed ? (k == "allow_always") : (k == "reject_always")
            })?["optionId"] as? String
        onLog?("[acp] permission kind=\(toolKind ?? "?") → \(allowed ? "allow" : "reject")")
        guard let optionID else {
            sendResult(id: id, result: ["outcome": ["outcome": "cancelled"]])
            return
        }
        sendResult(id: id, result: ["outcome": ["outcome": "selected", "optionId": optionID]])
    }

    private func permits(toolKind: String?) -> Bool {
        if case .all = scope { return true }
        switch toolKind {
            case "read", "search", "fetch": return scope.allows(.read)
            case "edit", "delete", "move": return scope.allows(.write)
            case "execute": return scope.allows(.execute)
            // Unknown / "other": only an unrestricted grant blanket-allows.
            default: return false
        }
    }

    private func respondReadFile(id: Any, params: [String: Any]) {
        guard scope.allows(.read) else {
            sendError(id: id, code: -32_001, message: "Read not permitted by grant scope.")
            return
        }
        guard let rawPath = params["path"] as? String,
            let path = containedPath(rawPath)
        else {
            sendError(id: id, code: -32_002, message: "Path is outside the permitted roots.")
            return
        }
        guard let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8)
        else {
            sendError(id: id, code: -32_003, message: "Cannot read '\(rawPath)' as UTF-8 text.")
            return
        }
        sendResult(id: id, result: ["content": text])
    }

    private func respondWriteFile(id: Any, params: [String: Any]) {
        guard scope.allows(.write) else {
            sendError(id: id, code: -32_001, message: "Write not permitted by grant scope.")
            return
        }
        guard let rawPath = params["path"] as? String,
            let content = params["content"] as? String,
            let path = containedPath(rawPath)
        else {
            sendError(id: id, code: -32_002, message: "Path is outside the permitted roots.")
            return
        }
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.data(using: .utf8)?.write(to: url)
            sendResult(id: id, result: [:])
        } catch {
            sendError(id: id, code: -32_003, message: "Write failed: \(error.localizedDescription)")
        }
    }

    /// Returns the symlink-resolved path iff it is contained within one of the
    /// session roots (boundary on a path separator so `<root>-x` can't escape).
    /// Mirrors `FilesystemActionManager.resolvedPath` containment. ACP fs paths
    /// are absolute, so they are matched directly against the roots.
    private func containedPath(_ rawPath: String) -> String? {
        let candidate = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        for root in roots {
            let rootWithSep = root.hasSuffix("/") ? root : root + "/"
            if resolved == root || resolved.hasPrefix(rootWithSep) {
                return resolved
            }
        }
        return nil
    }

    // MARK: Outgoing responses

    private func sendResult(id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func sendError(id: Any, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        Task { [transport] in try? await transport.send(data) }
    }
}
#endif
