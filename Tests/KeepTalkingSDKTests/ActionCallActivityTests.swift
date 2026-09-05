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

actor ActionExecutionCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

struct ActionCallActivityTests {
    @Test("an inbound call claiming this node's own identity is refused")
    func inboundSelfImpersonationIsRefused() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let node = KeepTalkingNode(id: UUID())
        let context = KeepTalkingContext(id: UUID())
        try await node.save(on: store.database)
        try await context.save(on: store.database)
        let nodeID = try #require(node.id)
        let contextID = try #require(context.id)

        let executions = ActionExecutionCounter()
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: nodeID),
            primitiveRegistry: KeepTalkingPrimitiveRegistry(
                toolParameters: { _ in ["type": AIProxyJSONValue.string("object")] },
                callAction: { _, _, _ in
                    await executions.record()
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
        let actionID = try #require(action.id)

        // Grant the action to this node, so authorization would ALLOW the call.
        // The point of the test is that identity, not permission, is what stops
        // it: these are exactly the self-grants a spoofer would be inheriting.
        let identityRelation = try KeepTalkingNodeRelation(
            from: node,
            to: node,
            relationship: .owner
        )
        try await identityRelation.save(on: store.database)
        var grant = KeepTalkingGrantTransaction()
        grant.grant(in: contextID, actionID: actionID, to: nodeID)
        try await KeepTalkingClient.grantActionPermission(
            transaction: grant,
            node: node,
            on: store.database
        )

        // Arrives over the wire claiming to be us — impossible for a genuine
        // local call, which never leaves the node.
        try await client.handleIncomingActionCallRequest(
            KeepTalkingActionCallRequest(
                contextID: contextID,
                callerNodeID: nodeID,
                targetNodeID: nodeID,
                call: KeepTalkingActionCall(action: actionID)
            )
        )

        #expect(await executions.count == 0)
    }

    @Test("local action activity is ordered once and ends after cancellation")
    func localActionActivityLifecycle() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
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
        let contextID = try #require(context.id)

        // The execution gate consults grants for (caller, context) with no
        // special case for the action's own host, so a self-hosted call needs
        // the same relation-plus-grant a remote caller does. Build both through
        // the production paths: the owner identity relation this node keeps to
        // itself, then a grant over it.
        let identityRelation = try KeepTalkingNodeRelation(
            from: node,
            to: node,
            relationship: .owner
        )
        try await identityRelation.save(on: store.database)

        var grant = KeepTalkingGrantTransaction()
        grant.grant(in: contextID, actionID: actionID, to: nodeID)
        try await KeepTalkingClient.grantActionPermission(
            transaction: grant,
            node: node,
            on: store.database
        )

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
        #expect(activities.map(\.phase.isEnded) == [false, true, false, true])
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
            localStore: try await KeepTalkingInMemoryStore.make()
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
        #expect(activities.map(\.phase) == [.began, .ended(.failure)])
        #expect(activities.first?.callerNodeID == selfNodeID)
        #expect(activities.first?.targetNodeID == remoteNodeID)
    }

    @Test("reserved action calls do not emit visible activity")
    func reservedActionsAreExcluded() async throws {
        let nodeID = UUID()
        let contextID = UUID()
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: nodeID),
            localStore: try await KeepTalkingInMemoryStore.make()
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
