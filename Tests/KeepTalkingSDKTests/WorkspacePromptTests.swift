import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import KeepTalkingSDK

private struct FakeWorkspace: KeepTalkingWorkspaceProviding {
    let manifest = KeepTalkingWorkspaceManifest(
        title: "Architecture board",
        kind: .canvas,
        schema: "excalidraw-scene",
        granularities: [.selection, .viewport, .full]
    )
    var fullFails = false

    func snapshot(granularity: KeepTalkingWorkspaceGranularity) async throws -> KeepTalkingWorkspaceSnapshot {
        let text: String
        switch granularity {
            case .full:
                if fullFails { throw CancellationError() }
                text = String(repeating: "[Auth Service] --\"POST /token\"--> [API Gateway]\n", count: 200)
            case .viewport:
                text = String(repeating: "[Auth Service] --\"POST /token\"--> [API Gateway]\n", count: 8)
            case .selection:
                text = "Selected: [Auth Service]"
        }
        return KeepTalkingWorkspaceSnapshot(
            granularity: granularity,
            stats: .init(totalElements: 47, visibleElements: 8, selectedElements: 1, groups: 12, connections: 30),
            liftedText: text
        )
    }
}

private struct WritableWorkspace: KeepTalkingWorkspaceProviding {
    let manifest = KeepTalkingWorkspaceManifest(
        title: "Canvas", kind: .canvas, schema: "excalidraw-scene", granularities: [.full],
        mutations: ["addElement"], mutationGuide: "payload is a skeleton {type, x, y}")
    let received: NIOLockedValueBox<[KeepTalkingWorkspaceMutation]> = .init([])

    func snapshot(granularity: KeepTalkingWorkspaceGranularity) async throws -> KeepTalkingWorkspaceSnapshot {
        .init(granularity: granularity, stats: .init(totalElements: 1), liftedText: "[A]")
    }

    func applyMutations(_ mutations: [KeepTalkingWorkspaceMutation]) async throws -> KeepTalkingWorkspaceMutationResult
    {
        received.withLockedValue { $0 += mutations }
        return .init(applied: mutations.count, failed: 0, createdElementIDs: ["new-1"])
    }
}

private actor WorkspaceScriptedModel: AIConnector {
    nonisolated let capabilities = AIConnectorCapabilities(supportsNativeToolCalling: true)
    private(set) var requests: [(messages: [AIMessage], tools: [String], configuration: AITurnConfiguration?)] = []
    var consultReply = #"{"relevant": false}"#

    func setConsultReply(_ reply: String) { consultReply = reply }

    func completeTurn(
        messages: [AIMessage],
        tools: [KeepTalkingActionToolDefinition],
        model: String,
        toolChoice: AIToolChoice?,
        stage: AIStage,
        configuration: AITurnConfiguration?,
        toolExecutor: (@Sendable ([AIToolCall]) async throws -> [AIMessage])?
    ) async throws -> AITurnResult {
        requests.append((messages, tools.map(\.functionName), configuration))
        if messages.last?.content?.text.contains("Consultation —") == true {
            return AITurnResult(assistantText: consultReply, toolCalls: [])
        }
        return AITurnResult(assistantText: "Reply \(requests.count).", toolCalls: [])
    }
}

struct WorkspacePromptTests {
    private static let section = KeepTalkingWorkspaceSection(
        manifest: FakeWorkspace().manifest,
        snapshot: .init(
            granularity: .viewport,
            stats: .init(totalElements: 47, visibleElements: 8, selectedElements: 1, groups: 12, connections: 30),
            liftedText: "[Auth Service] --\"POST /token\"--> [API Gateway]"
        )
    )

    @Test("a workspace section renders as its own prompt block")
    func sectionRenders() {
        let text = OrchestrationPromptFactor.workspace(
            Self.section, snapshotTool: "kt_workspace_snapshot", mutateTool: "kt_workspace_mutate"
        ).rendered
        #expect(text.hasPrefix("§ Workspace: Architecture board"))
        #expect(text.contains("Schema: excalidraw-scene. Granularity: viewport."))
        #expect(text.contains("47 elements, 8 visible, 1 selected, 12 groups, 30 connections"))
        #expect(text.hasSuffix("[Auth Service] --\"POST /token\"--> [API Gateway]"))
        #expect(text.contains("call kt_workspace_snapshot"))
        #expect(text.contains("It is read-only for you."))
    }

    @Test("the legacy group chat puts workspaces after side notes, before the conversation context")
    func legacyPlacement() {
        let factors = OrchestrationPromptFactor.groupChat(
            tools: KeepTalkingClient.promptToolNames,
            workspaces: [Self.section],
            contextTranscript: "Available actions:\n- action: X",
            currentDate: "2026-11-03 10:00",
            platform: "macOS"
        )
        let sideNotes = factors.firstIndex(of: .sideNotes([]))
        let workspace = factors.firstIndex(
            of: .workspace(Self.section, snapshotTool: "kt_workspace_snapshot", mutateTool: "kt_workspace_mutate"))
        let context = factors.firstIndex(
            of: .conversationContext(transcript: "Available actions:\n- action: X", scope: .whole)
        )
        #expect(sideNotes != nil && workspace != nil && context != nil)
        #expect(sideNotes! < workspace! && workspace! < context!)
    }

    @Test("the orchestrated group chat keeps workspaces out of the stable prompt")
    func orchestratedPlacement() {
        let factors = OrchestrationPromptFactor.groupChat(
            tools: KeepTalkingClient.promptToolNames,
            workspaces: [Self.section],
            contextTranscript: "",
            currentDate: "2026-11-03 10:00",
            platform: "macOS",
            layout: .orchestrated
        )
        #expect(
            !factors.contains(
                .workspace(Self.section, snapshotTool: "kt_workspace_snapshot", mutateTool: "kt_workspace_mutate")))
    }

    @Test("the pull takes the largest granularity that fits the provider's share")
    func pullPicksGranularityByBudget() async throws {
        try await AgentSurface.with { surface in
            let client = surface.client
            client.setWorkspaceProviders([FakeWorkspace()])

            let roomy = await client.workspaceSections(policy: .init(totalTokenBudget: 4000))
            #expect(roomy.map(\.snapshot.granularity) == [.full])

            let tight = await client.workspaceSections(policy: .init(totalTokenBudget: 200))
            #expect(tight.map(\.snapshot.granularity) == [.viewport])

            client.setWorkspaceProviders([FakeWorkspace(fullFails: true)])
            let fallback = await client.workspaceSections(policy: .init(totalTokenBudget: 4000))
            #expect(fallback.map(\.snapshot.granularity) == [.viewport])

            client.setWorkspaceProviders([])
            #expect(await client.workspaceSections().isEmpty)
        }
    }

    @Test("the tools appear with a known workspace, the writer only for a writable live one")
    func toolsFollowTheWorkspaces() async throws {
        try await AgentSurface.with { surface in
            let client = surface.client
            #expect(client.workspaceTools().isEmpty)

            client.setWorkspaceProviders([FakeWorkspace()])
            #expect(
                client.workspaceTools().map(\.functionName) == [KeepTalkingClient.workspaceSnapshotToolFunctionName])

            let writable = WritableWorkspace()
            client.setWorkspaceProviders([writable])
            let tools = client.workspaceTools()
            #expect(
                tools.map(\.functionName) == [
                    KeepTalkingClient.workspaceSnapshotToolFunctionName,
                    KeepTalkingClient.workspaceMutateToolFunctionName,
                ])
            #expect(tools[1].description.contains("payload is a skeleton {type, x, y}"))

            let read = await client.executeWorkspaceSnapshotToolCall(
                rawArguments: "{\"schema\":\"excalidraw-scene\",\"granularity\":\"full\"}")
            #expect(read.contains("\"text\":\"[A]\""))

            let written = await client.executeWorkspaceMutateToolCall(
                rawArguments:
                    "{\"schema\":\"excalidraw-scene\",\"mutations\":[{\"operation\":\"addElement\",\"payload\":{\"type\":\"rectangle\",\"x\":1}}]}"
            )
            #expect(written.contains("\"applied\":1"))
            #expect(written.contains("new-1"))
            let received = writable.received.withLockedValue { $0 }
            #expect(received.first?.operation == "addElement")
            #expect(received.first?.payloadJSON.contains("\"type\":\"rectangle\"") == true)

            client.setWorkspaceProviders([])
            client.recordWorkspaceLift(
                manifest: writable.manifest, snapshot: .init(granularity: .full, stats: .init(), liftedText: "[cached]")
            )
            #expect(
                client.workspaceTools().map(\.functionName) == [KeepTalkingClient.workspaceSnapshotToolFunctionName])
            let cached = await client.executeWorkspaceSnapshotToolCall(
                rawArguments: "{\"schema\":\"excalidraw-scene\"}")
            #expect(cached.contains("[cached]") && cached.contains("no page is open"))
            let refused = await client.executeWorkspaceMutateToolCall(
                rawArguments:
                    "{\"schema\":\"excalidraw-scene\",\"mutations\":[{\"operation\":\"addElement\",\"payload\":{}}]}")
            #expect(refused.contains("\"ok\":false"))
        }
    }

    @Test("a big workspace is read by a consult over its lift; the collector gets the findings, a small one the lift")
    func workspaceConsult() async throws {
        let model = WorkspaceScriptedModel()
        try await AgentSurface.with(aiConnector: model) { surface in
            let client = surface.client
            var strategy = KeepTalkingOrchestrationStrategy.orchestrated
            strategy.consultsStoredThreads = false
            let agent = KeepTalkingAgentConfiguration(
                main: .init(connector: model, model: "test"), orchestrationStrategy: strategy)

            let big = FakeWorkspace()
            client.setWorkspaceProviders([big])
            let lift = try await big.snapshot(granularity: .full).liftedText
            await model.setConsultReply(
                #"{"relevant": true, "facts": ["[Auth Service] issues tokens to [API Gateway]"], "elements": ["auth", "gateway"]}"#
            )
            _ = try await client.runDequeuedAIPrompt("what talks to the gateway?", in: surface.contextID, agent: agent)

            let consults = await model.requests.filter { $0.configuration?.telemetry?.role == .consult }
            #expect(consults.count == 1)
            let prefix = consults.first?.messages.prefix(2) ?? []
            #expect(prefix.last?.content?.text == lift)
            #expect(prefix.last?.cacheBoundary == .durable)
            #expect(consults.first?.tools.isEmpty == true)
            #expect(consults.first?.messages.last?.content?.text.contains("Consultation —") == true)

            let collector = await model.requests.last { $0.configuration?.telemetry?.role == .collector }
            let trailing = collector?.messages.last?.content?.text ?? ""
            #expect(trailing.contains("§ Workspace: Architecture board"))
            #expect(trailing.contains("- [Auth Service] issues tokens to [API Gateway]"))
            #expect(trailing.contains("Elements concerned: auth, gateway"))
            #expect(!trailing.contains("POST /token"))
            #expect(trailing.contains("kt_workspace_snapshot"))

            client.setWorkspaceProviders([WritableWorkspace()])
            _ = try await client.runDequeuedAIPrompt("and now?", in: surface.contextID, agent: agent)
            #expect(await model.requests.filter { $0.configuration?.telemetry?.role == .consult }.count == 1)
            let main = await model.requests.last
            #expect(main?.configuration?.telemetry?.role == .main)
            let inline = main?.messages.last?.content?.text ?? ""
            #expect(inline.contains("§ Workspace: Canvas") && inline.hasSuffix("[A]"))
        }
    }

    @Test("a payload's resourceHandle reaches the workspace as the attachment inlined")
    func resourceHandlesInline() async throws {
        try await AgentSurface.with { surface in
            let client = surface.client
            let bytes = Data("not really a png".utf8)
            let blobID = try await client.storeBlob(bytes, mimeType: "image/png", pathExtension: "png")
            let image = KeepTalkingContextAttachment(
                id: UUID(), context: surface.context, sender: .node(node: surface.nodeID), blobID: blobID,
                filename: "diagram.png", mimeType: "image/png", byteCount: bytes.count, metadata: .init())
            let note = KeepTalkingContextAttachment(
                id: UUID(), context: surface.context, sender: .node(node: surface.nodeID), blobID: blobID,
                filename: "notes.txt", mimeType: "text/plain", byteCount: bytes.count, metadata: .init())
            try await image.save(on: surface.store.database)
            try await note.save(on: surface.store.database)
            let imageHandle = KTResourceManifest.agentHandle(kind: .attachment, id: try image.requireID())
            let noteHandle = KTResourceManifest.agentHandle(kind: .attachment, id: try note.requireID())

            let writable = WritableWorkspace()
            client.setWorkspaceProviders([writable])
            let written = await client.executeWorkspaceMutateToolCall(
                rawArguments: """
                    {"schema":"excalidraw-scene","mutations":[
                      {"operation":"addImage","payload":{"resourceHandle":"\(imageHandle)","x":10,"y":20}},
                      {"operation":"addImage","payload":{"resourceHandle":"\(noteHandle)","x":0,"y":0}},
                      {"operation":"addImage","payload":{"resourceHandle":"KT_ATTACHMENT_NOPE","x":0,"y":0}}
                    ]}
                    """)
            #expect(written.contains("\"applied\":1"))
            #expect(written.contains("\"failed\":2"))
            #expect(written.contains("only images"))
            #expect(written.contains("No attachment KT_ATTACHMENT_NOPE"))

            let received = writable.received.withLockedValue { $0 }
            #expect(received.count == 1)
            let payload = try #require(
                try JSONSerialization.jsonObject(with: Data(received[0].payloadJSON.utf8)) as? [String: Any])
            #expect(payload["resourceHandle"] == nil)
            let resource = try #require(payload["resource"] as? [String: Any])
            #expect(resource["id"] as? String == image.id?.uuidString.lowercased())
            #expect(resource["name"] as? String == "diagram.png")
            #expect(resource["mimeType"] as? String == "image/png")
            #expect(resource["dataURL"] as? String == "data:image/png;base64,\(bytes.base64EncodedString())")
            #expect(payload["x"] as? Int == 10)
            let held = try await client.workspaceResources(schema: "excalidraw-scene")
            #expect(held.map(\.resourceID) == [try image.requireID()])
        }
    }
}
