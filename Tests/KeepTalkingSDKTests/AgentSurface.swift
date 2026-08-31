import AIProxy
import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

/// Drives the SDK the way the model drives it.
///
/// A test hands in the raw JSON arguments an LLM would emit for a tool call and
/// gets back the decoded JSON payload that same LLM would read. Everything in
/// between is the production stack — grant resolution, the action-call
/// controller, the executor, IO staging, resource delivery — so a failure here
/// is a failure a live conversation would have hit.
///
/// This exists because the interesting filesystem bugs are not in any one
/// function: they live in the seam between "what the executor returned" and
/// "what the agent can actually do next". Unit-testing the executor alone
/// cannot see, for example, that `get-file` succeeded but handed the agent
/// nothing it could pass to another action.
final class AgentSurface {
    let store: KeepTalkingInMemoryStore
    let client: KeepTalkingClient
    let node: KeepTalkingNode
    let context: KeepTalkingContext
    let nodeID: UUID
    let contextID: UUID

    private init(
        store: KeepTalkingInMemoryStore,
        client: KeepTalkingClient,
        node: KeepTalkingNode,
        context: KeepTalkingContext
    ) throws {
        self.store = store
        self.client = client
        self.node = node
        self.context = context
        self.nodeID = try node.requireID()
        self.contextID = try context.requireID()
    }

    /// Boots a single-node stack: in-memory database, one node, one context,
    /// and the owner identity relation self-calls are authorised through.
    static func make() async throws -> AgentSurface {
        let store = try await KeepTalkingInMemoryStore.make()
        let node = KeepTalkingNode(id: UUID())
        let context = KeepTalkingContext(id: UUID())
        try await node.save(on: store.database)
        try await context.save(on: store.database)

        let identity = try KeepTalkingNodeRelation(
            from: node, to: node, relationship: .owner)
        try await identity.save(on: store.database)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                contextID: try context.requireID(),
                node: try node.requireID()
            ),
            localStore: store
        )
        return try AgentSurface(
            store: store, client: client, node: node, context: context)
    }

    func shutdown() async {
        await store.shutdown()
    }

    // MARK: - Mounting actions

    /// Registers a filesystem action rooted at `root` and grants this node full
    /// access to it, returning the façade a test calls tools through.
    @discardableResult
    func mountFilesystem(
        root: URL,
        name: String = "filesystem",
        permission: KeepTalkingActionScope? = nil
    ) async throws -> FilesystemTool {
        let action = try await KeepTalkingClient.registerAction(
            payload: .filesystem(
                KeepTalkingFilesystemBundle(name: name, rootPath: root.path)),
            node: node,
            on: store.database
        )
        let actionID = try action.requireID()
        var transaction = KeepTalkingGrantTransaction()
        transaction.grant(
            in: contextID, actionID: actionID, to: nodeID, permission: permission)
        try await KeepTalkingClient.grantActionPermission(
            transaction: transaction, node: node, on: store.database)
        return FilesystemTool(surface: self, actionID: actionID, root: root)
    }

    // MARK: - The model-facing call

    /// Issues one tool call exactly as the agent proxy would and decodes the
    /// payload the model receives.
    ///
    /// - Parameters:
    ///   - operation: The filesystem tool name, e.g. `"get-file"`. Rides as the
    ///     definition's `targetName`, which is what wraps the flat arguments into
    ///     the `{tool, arguments}` envelope the executor unpacks.
    ///   - arguments: The flat argument object an LLM emits for that tool.
    ///   - inputHandles: Resource handles the agent is feeding into this call.
    ///   - outputPersistence: What the agent asked produced files to become.
    func call(
        actionID: UUID,
        operation: String,
        arguments: [String: Any],
        inputHandles: [UUID]? = nil,
        outputPersistence: KeepTalkingActionOutputHandle.Persistence? = nil,
        outputName: String = "result"
    ) async throws -> AgentReply {
        let definition = KeepTalkingActionToolDefinition(
            functionName: "kt_test_\(operation.replacingOccurrences(of: "-", with: "_"))",
            actionID: actionID,
            ownerNodeID: nodeID,
            source: .filesystem,
            targetName: operation,
            description: "test harness proxy for \(operation)",
            parameters: ["type": .string("object")]
        )
        let outputHandles = outputPersistence.map {
            [
                KeepTalkingActionOutputHandle(
                    id: UUID(), name: outputName, persistence: $0)
            ]
        }
        let proxied = try await client.executeActionProxyToolCall(
            functionName: definition.functionName,
            definition: definition,
            rawArguments: Self.jsonString(arguments),
            context: context,
            inputHandles: inputHandles,
            outputHandles: outputHandles
        )
        return try AgentReply(payload: proxied.payload)
    }

    /// Resolves a handle the agent was given back to bytes on disk — the same
    /// lookup the executor performs when the agent passes it as an input.
    /// `nil` means the agent was handed a handle it could not actually use.
    func resolve(_ handle: KTResourceManifest.AgentResource) async -> URL? {
        // A friendly handle carries a 24-bit code, not the UUID, so it cannot be
        // parsed back to an id — and a resource decoded from the wire has no
        // `resourceID` either, since only the handle travels. Resolve it the way
        // the real executor does: against the handles that actually exist for
        // this caller.
        let id: UUID
        if let known = handle.resourceID {
            id = known
        } else {
            let candidates = await client.stagedFileStore.handles(forCaller: nodeID)
            guard
                case .resolved(let resolved) = KTResourceManifest.resolveAgentHandle(
                    handle.handle, among: candidates)
            else { return nil }
            id = resolved
        }
        return await client.stagedFileStore
            .file(handle: id, callerNodeID: nodeID)?.url
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

// MARK: - Scoped lifecycle

extension AgentSurface {
    /// Boots a stack with one filesystem action mounted on a throwaway
    /// directory, runs `body`, and tears both down on every exit path.
    ///
    /// Scoped rather than `defer`-based: tearing down needs `await`, and a
    /// `defer { Task { ... } }` would both outlive the test and hand a
    /// non-Sendable surface to another isolation context.
    static func withFilesystem<T>(
        _ body: (AgentSurface, FilesystemTool) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-surface-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let surface = try await AgentSurface.make()
        do {
            let tool = try await surface.mountFilesystem(root: root)
            let value = try await body(surface, tool)
            await surface.shutdown()
            try? FileManager.default.removeItem(at: root)
            return value
        } catch {
            await surface.shutdown()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}

// MARK: - Filesystem façade

extension AgentSurface {
    /// One mounted filesystem action, with the file-side helpers a test needs to
    /// set up fixtures and check what the tools did to them.
    struct FilesystemTool {
        let surface: AgentSurface
        let actionID: UUID
        let root: URL

        @discardableResult
        func call(
            _ operation: String,
            _ arguments: [String: Any] = [:],
            inputHandles: [UUID]? = nil,
            outputPersistence: KeepTalkingActionOutputHandle.Persistence? = nil,
            outputName: String = "result"
        ) async throws -> AgentReply {
            try await surface.call(
                actionID: actionID,
                operation: operation,
                arguments: arguments,
                inputHandles: inputHandles,
                outputPersistence: outputPersistence,
                outputName: outputName)
        }

        // MARK: Fixture helpers

        func url(_ name: String) -> URL {
            root.appendingPathComponent(name)
        }

        @discardableResult
        func seed(_ name: String, bytes: Data) throws -> URL {
            let target = url(name)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try bytes.write(to: target)
            return target
        }

        @discardableResult
        func seed(_ name: String, text: String) throws -> URL {
            try seed(name, bytes: Data(text.utf8))
        }

        func bytes(_ name: String) -> Data? {
            try? Data(contentsOf: url(name))
        }

        func size(_ name: String) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: url(name).path))?[.size]
                as? Int
        }

        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: url(name).path)
        }
    }
}

// MARK: - What the model sees

/// The decoded tool payload the model receives — the same JSON object
/// `renderAgentToolPayload` builds, parsed into something a test can assert on.
struct AgentReply {
    let raw: String
    let ok: Bool
    let content: [String]
    let errorMessage: String
    let producedResources: [KTResourceManifest.AgentResource]

    init(payload: String) throws {
        raw = payload
        let object =
            (try? JSONSerialization.jsonObject(with: Data(payload.utf8)))
            as? [String: Any] ?? [:]
        ok = object["ok"] as? Bool ?? false
        content = object["content"] as? [String] ?? []
        errorMessage = object["error_message"] as? String ?? ""
        // Decode through the manifest's own reader, not JSONDecoder: the wire
        // form is snake_case (`mime_type`, `byte_count`) and does not match the
        // synthesized Codable keys.
        producedResources = (object["produced_resources"] as? [[String: Any]] ?? [])
            .compactMap(KTResourceManifest.AgentResource.init(jsonObject:))
    }

    /// Everything the model would read as the tool's textual result.
    var text: String { content.joined(separator: "\n") }

    var handles: [KTResourceManifest.AgentResource] { producedResources }

    func handles(ofKind kind: String) -> [KTResourceManifest.AgentResource] {
        producedResources.filter { $0.kind == kind }
    }

    /// The single produced resource, when a test expects exactly one.
    func onlyHandle(
        _ comment: Comment = "expected exactly one produced resource",
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> KTResourceManifest.AgentResource {
        try #require(
            producedResources.count == 1 ? producedResources.first : nil,
            comment, sourceLocation: sourceLocation)
    }
}
