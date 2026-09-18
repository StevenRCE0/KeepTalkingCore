import AIProxy
import Foundation
import Testing

@testable import KeepTalkingSDK

struct ExecutorRegistrationSignalTests {
    @Test("registering local executors reports each action, finalizing, then idle")
    func registrationProgress() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let node = KeepTalkingNode(id: UUID())
        let context = KeepTalkingContext(id: UUID())
        try await node.save(on: store.database)
        try await context.save(on: store.database)
        let nodeID = try #require(node.id)
        let contextID = try #require(context.id)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: nodeID),
            primitiveRegistry: KeepTalkingPrimitiveRegistry(
                toolParameters: { _ in ["type": AIProxyJSONValue.string("object")] },
                callAction: { _, _, _ in KeepTalkingPrimitiveActionResponse(text: "done") }
            ),
            localStore: store
        )
        let action = try await KeepTalkingClient.registerAction(
            payload: .primitive(
                KeepTalkingPrimitiveBundle(
                    name: "open-with-url",
                    indexDescription: "Open a URL",
                    action: .openWithURL
                )
            ),
            node: node,
            on: store.database
        )
        // Registration covers granted actions only: an owned action reaches
        // this node's own executors through a self-grant, as the app does.
        let selfRelation = try KeepTalkingNodeRelation(
            from: node,
            to: node,
            relationship: .trustedInAllContext
        )
        try await selfRelation.save(on: store.database)
        try await client.grantActionPermission(
            actionID: try action.requireID(),
            toNodeID: nodeID,
            scope: .all
        )

        let progress = SignalRecorder<KeepTalkingExecutorRegistration>()
        client.executorRegistration.observe { progress.record($0) }
        await progress.waitForCount(1)

        try await client.registerLocalActionsInExecutors()

        await progress.waitForCount(4)
        #expect(
            progress.snapshot == [
                .idle,
                .registering(source: "primitive", name: "open-with-url", completed: 0, total: 1),
                .finalizing,
                .idle,
            ]
        )
        #expect(client.executorRegistration.current == .idle)
    }
}
