import Foundation
import Logging
import MCP
import Testing

@testable import KeepTalkingSDK

// MARK: - Auth method parsing (cross-platform: the model is not macOS-gated)

struct ACPAuthMethodTests {
    @Test("Auth methods parse off the wire, defaulting type to `agent`")
    func parsesAdvertisedMethods() {
        let method = KeepTalkingACPAuthMethod(json: [
            "id": "agent-login", "name": "Log in", "description": "Use your account",
        ])
        #expect(method?.id == "agent-login")
        #expect(method?.name == "Log in")
        #expect(method?.detail == "Use your account")
        #expect(method?.type == "agent")
        #expect(method?.isDrivable == true)
    }

    @Test("A terminal-type method is advertised but not drivable by KeepTalking")
    func terminalMethodIsNotDrivable() {
        let method = KeepTalkingACPAuthMethod(json: [
            "id": "cli", "name": "claude login", "type": "terminal",
        ])
        #expect(method?.isDrivable == false)
    }

    @Test("A malformed method is dropped without poisoning the advertised set")
    func malformedMethodIsDropped() {
        let raw: [[String: Any]] = [
            ["name": "no id here"],
            ["id": "", "name": "blank id"],
            ["id": "good", "name": "Good"],
        ]
        let parsed = raw.compactMap(KeepTalkingACPAuthMethod.init(json:))
        #expect(parsed.map(\.id) == ["good"])
        // A method with no `name` falls back to its id rather than failing.
        #expect(KeepTalkingACPAuthMethod(json: ["id": "bare"])?.name == "bare")
    }
}

struct ACPCredentialStoreTests {
    @Test("Credentials round-trip through the keychain seam")
    func roundTrip() async throws {
        let store = KeepTalkingACPCredentialStore(keychain: KeepTalkingInMemoryKeychainStore())
        let actionID = UUID()
        try await store.store(
            KeepTalkingACPCredentials(
                environment: ["ANTHROPIC_API_KEY": "sk-test"], methodID: "agent-login"),
            actionID: actionID)

        let loaded = try await store.load(actionID: actionID)
        #expect(loaded?.environment["ANTHROPIC_API_KEY"] == "sk-test")
        #expect(loaded?.methodID == "agent-login")
    }

    @Test("Clearing the auth method keeps the environment, and empty clears the entry")
    func setMethodIDPreservesEnvironment() async throws {
        let store = KeepTalkingACPCredentialStore(keychain: KeepTalkingInMemoryKeychainStore())
        let actionID = UUID()
        try await store.store(
            KeepTalkingACPCredentials(environment: ["K": "v"], methodID: "m"),
            actionID: actionID)

        try await store.setMethodID(nil, actionID: actionID)
        let afterClear = try await store.load(actionID: actionID)
        #expect(afterClear?.environment["K"] == "v")
        #expect(afterClear?.methodID == nil)

        try await store.store(KeepTalkingACPCredentials(), actionID: actionID)
        #expect(try await store.load(actionID: actionID) == nil)
    }
}

#if os(macOS)

// MARK: - A scripted ACP agent, driven over the real ACPSession wire

/// Stands in for an agent subprocess: decodes what `ACPManager` sends and replies
/// with canned JSON-RPC, so the handshake, the `auth_required` retry and the
/// prompt turn all run through the production code path.
private actor ScriptedACPAgent: Transport {
    nonisolated let logger = Logger(label: "test.acp.agent")

    /// Methods advertised in the `initialize` response.
    private let authMethods: [[String: Any]]
    /// Version the agent claims to speak.
    private let agentProtocolVersion: Int
    /// While true, `session/new` is refused with -32000.
    private var requiresAuth: Bool

    private var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?

    /// Everything the client asked for, in order — the assertions read this.
    private(set) var receivedMethods: [String] = []
    private(set) var authenticatedWith: [String] = []

    /// When set, `session/new` fails with this code plus a `data` payload —
    /// how a real agent reports a fault behind the bare JSON-RPC label.
    private let sessionFailure: (code: Int, data: [String: Any])?

    init(
        authMethods: [[String: Any]] = [],
        protocolVersion: Int = 1,
        requiresAuth: Bool = false,
        sessionFailure: (code: Int, data: [String: Any])? = nil
    ) {
        self.authMethods = authMethods
        self.agentProtocolVersion = protocolVersion
        self.requiresAuth = requiresAuth
        self.sessionFailure = sessionFailure
    }

    func connect() async throws {}

    func disconnect() async {
        continuation?.finish()
        continuation = nil
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func send(_ data: Data) async throws {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = message["method"] as? String,
            let id = message["id"]
        else { return }
        receivedMethods.append(method)

        switch method {
            case "initialize":
                reply(
                    id: id,
                    result: [
                        "protocolVersion": agentProtocolVersion,
                        "authMethods": authMethods,
                        "agentCapabilities": [String: Any](),
                    ])
            case "authenticate":
                let params = message["params"] as? [String: Any] ?? [:]
                authenticatedWith.append(params["methodId"] as? String ?? "")
                requiresAuth = false
                reply(id: id, result: [String: Any]())
            case "session/new":
                if let sessionFailure {
                    emit([
                        "jsonrpc": "2.0", "id": id,
                        "error": [
                            "code": sessionFailure.code, "message": "Internal error",
                            "data": sessionFailure.data,
                        ],
                    ])
                } else if requiresAuth {
                    fail(id: id, code: -32000, message: "Authentication required")
                } else {
                    reply(id: id, result: ["sessionId": "session-1"])
                }
            case "session/prompt":
                // One streamed chunk, then the turn ends.
                notify(text: "done")
                reply(id: id, result: ["stopReason": "end_turn"])
            default:
                fail(id: id, code: -32601, message: "Method not supported: \(method)")
        }
    }

    private func reply(id: Any, result: [String: Any]) {
        emit(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func fail(id: Any, code: Int, message: String) {
        emit(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func notify(text: String) {
        emit([
            "jsonrpc": "2.0", "method": "session/update",
            "params": [
                "sessionId": "session-1",
                "update": [
                    "sessionUpdate": "agent_message_chunk",
                    "content": ["type": "text", "text": text],
                ],
            ],
        ])
    }

    private func emit(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        continuation?.yield(data)
    }
}

private struct AliveProcessHandler: MCPStdioProcessHandling {
    // Never "exited": that is what lets the test prove a protocol error is
    // reported as itself rather than being masked as `agentExited`.
    func terminationStatus() -> Int32? { nil }
    func terminate() {}
}

private struct ScriptedLauncher: MCPStdioTransportLaunching {
    let agent: ScriptedACPAgent
    /// Captures the environment the manager actually handed the subprocess.
    let observedEnvironment: EnvironmentBox

    func launchTransport(
        command: [String],
        environment: [String: String],
        stderrHandler: @escaping @Sendable (Data) -> Void,
        sandboxPolicy: KTSandboxPolicy?
    ) async throws -> MCPStdioTransportHandle {
        observedEnvironment.set(environment)
        return MCPStdioTransportHandle(
            transport: agent, processHandler: AliveProcessHandler())
    }
}

private final class EnvironmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: String] = [:]

    func set(_ new: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        value = new
    }

    func get() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

struct ACPAuthFlowTests {
    private func makeAction(
        environment: [String: String] = [:]
    ) -> (KeepTalkingAction, UUID) {
        let bundle = KeepTalkingACPBundle(
            name: "agent",
            command: ["fake-agent"],
            environment: environment,
            cwd: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        let action = KeepTalkingAction(
            payload: .acp(bundle), remoteAuthorisable: false, blockingAuthorisation: false)
        let actionID = UUID.v7()
        action.id = actionID
        return (action, actionID)
    }

    private func makeManager(
        agent: ScriptedACPAgent,
        credentialStore: KeepTalkingACPCredentialStore? = nil,
        environmentBox: EnvironmentBox = EnvironmentBox()
    ) -> ACPManager {
        ACPManager(
            nodeConfig: KeepTalkingConfig(contextID: UUID(), node: UUID()),
            stdioTransportLauncher: ScriptedLauncher(
                agent: agent, observedEnvironment: environmentBox),
            credentialStore: credentialStore,
            handshakeTimeoutSeconds: 5,
            promptGraceSeconds: 1,
            promptPollSeconds: 1
        )
    }

    @Test("An auth_required session/new triggers authenticate and one retry")
    func authRequiredIsResolvedInBand() async throws {
        let agent = ScriptedACPAgent(
            authMethods: [["id": "agent-login", "name": "Log in"]], requiresAuth: true)
        let store = KeepTalkingACPCredentialStore(keychain: KeepTalkingInMemoryKeychainStore())
        let manager = makeManager(agent: agent, credentialStore: store)
        let (action, actionID) = makeAction()
        try await manager.registerACPAction(action)

        let result = try await manager.callAction(
            action: action,
            call: KeepTalkingActionCall(action: actionID, arguments: ["prompt": .string("hi")]),
            scope: .all,
            callerIsRemote: false
        )

        #expect(result.isError != true)
        // The single advertised drivable method is taken without a handler, and
        // session/new is retried exactly once after authenticating.
        #expect(await agent.authenticatedWith == ["agent-login"])
        #expect(
            await agent.receivedMethods == [
                "initialize", "session/new", "authenticate", "session/new", "session/prompt",
            ])
        // The working method is remembered for the next spawn.
        #expect(try await store.load(actionID: actionID)?.methodID == "agent-login")
    }

    @Test("An agent that needs no auth never calls authenticate")
    func noAuthNeededSkipsAuthenticate() async throws {
        let agent = ScriptedACPAgent(authMethods: [["id": "agent-login", "name": "Log in"]])
        let manager = makeManager(agent: agent)
        let (action, actionID) = makeAction()

        _ = try await manager.callAction(
            action: action,
            call: KeepTalkingActionCall(action: actionID, arguments: ["prompt": .string("hi")]),
            scope: .all,
            callerIsRemote: false
        )

        #expect(await agent.authenticatedWith.isEmpty)
        #expect(await agent.receivedMethods == ["initialize", "session/new", "session/prompt"])
    }

    @Test("An ambiguous auth choice with no handler surfaces the advertised methods")
    func ambiguousChoiceNeedsAHandler() async throws {
        let agent = ScriptedACPAgent(
            authMethods: [
                ["id": "oauth", "name": "OAuth"],
                ["id": "api-key", "name": "API key"],
            ],
            requiresAuth: true)
        let manager = makeManager(agent: agent)
        let (action, actionID) = makeAction()

        await #expect(throws: ACPManagerError.self) {
            _ = try await manager.callAction(
                action: action,
                call: KeepTalkingActionCall(action: actionID, arguments: ["prompt": .string("hi")]),
                scope: .all,
                callerIsRemote: false
            )
        }
        #expect(await agent.authenticatedWith.isEmpty)
    }

    @Test("The installed handler picks the method, and a decline aborts the call")
    func handlerDrivesTheChoice() async throws {
        let agent = ScriptedACPAgent(
            authMethods: [
                ["id": "oauth", "name": "OAuth"],
                ["id": "api-key", "name": "API key"],
            ],
            requiresAuth: true)
        let store = KeepTalkingACPCredentialStore(keychain: KeepTalkingInMemoryKeychainStore())
        let manager = makeManager(agent: agent, credentialStore: store)
        let (action, actionID) = makeAction()

        await manager.setAuthHandler { _, methods in
            .selected(methodID: methods.last!.id)
        }
        _ = try await manager.callAction(
            action: action,
            call: KeepTalkingActionCall(action: actionID, arguments: ["prompt": .string("hi")]),
            scope: .all,
            callerIsRemote: false
        )
        #expect(await agent.authenticatedWith == ["api-key"])

        // A declined prompt fails the call rather than proceeding unauthenticated.
        let declining = ScriptedACPAgent(
            authMethods: [["id": "oauth", "name": "OAuth"]], requiresAuth: true)
        let declineManager = makeManager(agent: declining)
        await declineManager.setAuthHandler { _, _ in .declined }
        await #expect(throws: ACPManagerError.self) {
            _ = try await declineManager.callAction(
                action: action,
                call: KeepTalkingActionCall(action: actionID, arguments: ["prompt": .string("hi")]),
                scope: .all,
                callerIsRemote: false
            )
        }
        #expect(await declining.authenticatedWith.isEmpty)
    }

    @Test("A remembered method authenticates silently, without re-prompting")
    func rememberedMethodSkipsThePrompt() async throws {
        let agent = ScriptedACPAgent(
            authMethods: [
                ["id": "oauth", "name": "OAuth"],
                ["id": "api-key", "name": "API key"],
            ],
            requiresAuth: true)
        let store = KeepTalkingACPCredentialStore(keychain: KeepTalkingInMemoryKeychainStore())
        let (action, actionID) = makeAction()
        try await store.store(
            KeepTalkingACPCredentials(methodID: "api-key"), actionID: actionID)

        let manager = makeManager(agent: agent, credentialStore: store)
        await manager.setAuthHandler { _, _ in
            Issue.record("The handler must not run when a method is already remembered")
            return .cancelled
        }
        _ = try await manager.callAction(
            action: action,
            call: KeepTalkingActionCall(action: actionID, arguments: ["prompt": .string("hi")]),
            scope: .all,
            callerIsRemote: false
        )
        #expect(await agent.authenticatedWith == ["api-key"])
    }

    @Test("A foreign protocol version stops the handshake before any session opens")
    func versionMismatchIsAHardStop() async throws {
        let agent = ScriptedACPAgent(protocolVersion: 99)
        let manager = makeManager(agent: agent)
        let (action, actionID) = makeAction()

        await #expect(throws: ACPManagerError.self) {
            _ = try await manager.callAction(
                action: action,
                call: KeepTalkingActionCall(action: actionID, arguments: ["prompt": .string("hi")]),
                scope: .all,
                callerIsRemote: false
            )
        }
        #expect(await agent.receivedMethods == ["initialize"])
    }

    @Test("Preflight completes the handshake, reports auth methods, and opens no session")
    func preflightTestsInitializeOnly() async throws {
        let agent = ScriptedACPAgent(
            authMethods: [["id": "agent-login", "name": "Log in"]], requiresAuth: true)
        let manager = makeManager(agent: agent)
        let bundle = KeepTalkingACPBundle(
            name: "agent", command: ["fake-agent"],
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()))

        let methods = try await manager.preflightInitialize(bundle: bundle)

        #expect(methods.map(\.id) == ["agent-login"])
        // An agent that would demand auth still passes preflight: the handshake
        // is what is being tested, and auth belongs to a real call.
        #expect(await agent.receivedMethods == ["initialize"])
    }

    @Test("Preflight fails a foreign protocol version and an empty command")
    func preflightRejectsUnusableAgents() async throws {
        let manager = makeManager(agent: ScriptedACPAgent(protocolVersion: 99))
        await #expect(throws: ACPManagerError.self) {
            _ = try await manager.preflightInitialize(
                bundle: KeepTalkingACPBundle(
                    name: "agent", command: ["fake-agent"],
                    cwd: URL(fileURLWithPath: NSTemporaryDirectory())))
        }

        let emptyManager = makeManager(agent: ScriptedACPAgent())
        await #expect(throws: ACPManagerError.self) {
            _ = try await emptyManager.preflightInitialize(
                bundle: KeepTalkingACPBundle(
                    name: "agent", cwd: URL(fileURLWithPath: NSTemporaryDirectory())))
        }
    }

    @Test("An agent-side fault reports its `data` detail, not just \"Internal error\"")
    func agentErrorSurfacesItsDataDetail() async throws {
        // Exactly what @agentclientprotocol/claude-agent-acp returned when the
        // binary it spawns was corrupt: the label is useless, `data` is the answer.
        let agent = ScriptedACPAgent(
            sessionFailure: (code: -32603, data: ["details": "spawn Unknown system error -88"]))
        let manager = makeManager(agent: agent)
        let (action, actionID) = makeAction()

        var captured: String?
        do {
            _ = try await manager.callAction(
                action: action,
                call: KeepTalkingActionCall(action: actionID, arguments: ["prompt": .string("hi")]),
                scope: .all,
                callerIsRemote: false
            )
        } catch {
            captured = error.localizedDescription
        }
        let described = try #require(captured)
        #expect(described.contains("-32603"))
        #expect(described.contains("spawn Unknown system error -88"))
    }

    @Test("An agent whose own credentials expired is named, not called an internal error")
    func expiredAgentCredentialsAreNamed() async throws {
        // What @agentclientprotocol/claude-agent-acp actually returns when the
        // Claude CLI's OAuth session lapsed. It advertises no ACP auth methods,
        // so `authenticate` is not the fix and must not be attempted.
        let agent = ScriptedACPAgent(
            sessionFailure: (
                code: -32603, data: ["errorKind": "authentication_failed"]
            ))
        let manager = makeManager(agent: agent)
        let (action, actionID) = makeAction()

        var captured: Error?
        do {
            _ = try await manager.callAction(
                action: action,
                call: KeepTalkingActionCall(action: actionID, arguments: ["prompt": .string("hi")]),
                scope: .all,
                callerIsRemote: false
            )
        } catch {
            captured = error
        }
        guard case .agentCredentialsRejected = try #require(captured as? ACPManagerError) else {
            Issue.record("Expected agentCredentialsRejected, got \(String(describing: captured))")
            return
        }
        #expect(await agent.authenticatedWith.isEmpty)
        #expect(
            captured?.localizedDescription.contains("re-authenticate the agent's CLI") == true)
    }

    @Test("The keychain environment reaches the subprocess and overrides the payload")
    func storedEnvironmentIsInjected() async throws {
        let agent = ScriptedACPAgent()
        let store = KeepTalkingACPCredentialStore(keychain: KeepTalkingInMemoryKeychainStore())
        let box = EnvironmentBox()
        let (action, actionID) = makeAction(environment: ["PLAIN": "kept", "SECRET": "stale"])
        try await store.store(
            KeepTalkingACPCredentials(environment: ["SECRET": "sk-live"]), actionID: actionID)

        let manager = makeManager(agent: agent, credentialStore: store, environmentBox: box)
        _ = try await manager.callAction(
            action: action,
            call: KeepTalkingActionCall(action: actionID, arguments: ["prompt": .string("hi")]),
            scope: .all,
            callerIsRemote: false
        )

        let environment = box.get()
        #expect(environment["PLAIN"] == "kept")
        #expect(environment["SECRET"] == "sk-live")
    }
}

#endif
