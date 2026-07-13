import AIProxy
import Foundation
import Testing

@testable import KeepTalkingSDK

actor ActionCallActivityRecorder {
    private var activities: [KeepTalkingActionCallActivity] = []

    func record(_ activity: KeepTalkingActionCallActivity) {
        activities.append(activity)
    }

    func snapshot() -> [KeepTalkingActionCallActivity] {
        activities
    }

    func waitForCount(_ count: Int) async {
        while activities.count < count {
            await Task.yield()
        }
    }
}

struct ActionCallActivityTests {
    @Test("local action activity is ordered once and ends after cancellation")
    func localActionActivityLifecycle() async throws {
        let store = KeepTalkingInMemoryStore()
        let node = KeepTalkingNode(id: UUID())
        let context = KeepTalkingContext(id: UUID())
        try await node.save(on: store.database)
        try await context.save(on: store.database)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                contextID: try #require(context.id),
                node: try #require(node.id)
            ),
            primitiveRegistry: KeepTalkingPrimitiveRegistry(
                toolParameters: { _ in ["type": AIProxyJSONValue.string("object")] },
                callAction: { _, call, _ in
                    if case .bool(true) = call.arguments["wait"] {
                        try await Task.sleep(for: .seconds(30))
                    }
                    return KeepTalkingPrimitiveActionResponse(text: "done")
                }
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
        let recorder = ActionCallActivityRecorder()
        client.onActionCallActivity = { await recorder.record($0) }
        let actionID = try #require(action.id)
        let nodeID = try #require(node.id)

        let firstResult = try await client.dispatchActionCall(
            actionOwner: nodeID,
            call: KeepTalkingActionCall(action: actionID),
            context: context
        )
        #expect(!firstResult.isError)

        let task = Task {
            try await client.dispatchActionCall(
                actionOwner: nodeID,
                call: KeepTalkingActionCall(
                    action: actionID,
                    arguments: ["wait": .bool(true)]
                ),
                context: context
            )
        }
        await recorder.waitForCount(3)
        task.cancel()
        let cancelledResult = try await task.value
        let activities = await recorder.snapshot()

        #expect(cancelledResult.isError)
        #expect(activities.map(\.phase) == [.began, .ended, .began, .ended])
        #expect(Set(activities.map(\.requestID)).count == 2)
        #expect(activities.allSatisfy { $0.actionID == actionID })
    }

    @Test("outgoing remote activity ends when delivery fails")
    func outgoingRemoteActivityEndsOnFailure() async throws {
        let selfNodeID = UUID()
        let remoteNodeID = UUID()
        let context = KeepTalkingContext(id: UUID())
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                contextID: try #require(context.id),
                node: selfNodeID
            ),
            localStore: KeepTalkingInMemoryStore()
        )
        let recorder = ActionCallActivityRecorder()
        client.onActionCallActivity = { await recorder.record($0) }
        client.disconnect()

        do {
            _ = try await client.dispatchActionCall(
                actionOwner: remoteNodeID,
                call: KeepTalkingActionCall(action: UUID()),
                context: context
            )
            Issue.record("Expected remote delivery to fail while disconnected")
        } catch {}

        let activities = await recorder.snapshot()
        #expect(activities.map(\.phase) == [.began, .ended])
        #expect(activities.first?.callerNodeID == selfNodeID)
        #expect(activities.first?.targetNodeID == remoteNodeID)
    }

    @Test("reserved action calls do not emit visible activity")
    func reservedActionsAreExcluded() async throws {
        let nodeID = UUID()
        let contextID = UUID()
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: nodeID),
            localStore: KeepTalkingInMemoryStore()
        )
        let recorder = ActionCallActivityRecorder()
        client.onActionCallActivity = { await recorder.record($0) }

        _ = await client.executeActionCallRequest(
            KeepTalkingActionCallRequest(
                contextID: contextID,
                callerNodeID: nodeID,
                targetNodeID: nodeID,
                call: KeepTalkingActionCall(action: KeepTalkingClient.cancelActionID)
            ),
            context: nil
        )
        #if os(macOS)
        _ = await client.executeActionCallRequest(
            KeepTalkingActionCallRequest(
                contextID: contextID,
                callerNodeID: nodeID,
                targetNodeID: nodeID,
                call: KeepTalkingActionCall(action: KeepTalkingClient.stageFileActionID)
            ),
            context: nil
        )
        #endif

        #expect(await recorder.snapshot().isEmpty)
    }
}
