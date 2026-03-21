import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

struct RemoteActionCallTests {
    @Test("early remote action result is cached until the caller waits for it")
    func earlyRemoteActionResultIsCached() async throws {
        let requestID = UUID(uuidString: "10000000-0000-0000-0000-000000000000")!
        let contextID = UUID(uuidString: "20000000-0000-0000-0000-000000000000")!
        let callerNodeID = UUID(uuidString: "30000000-0000-0000-0000-000000000000")!
        let targetNodeID = UUID(uuidString: "40000000-0000-0000-0000-000000000000")!
        let actionID = UUID(uuidString: "50000000-0000-0000-0000-000000000000")!
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: contextID,
                node: callerNodeID
            ),
            localStore: KeepTalkingInMemoryStore()
        )
        let result = KeepTalkingActionCallResult(
            requestID: requestID,
            contextID: contextID,
            callerNodeID: callerNodeID,
            targetNodeID: targetNodeID,
            actionID: actionID,
            content: [.text("ok")]
        )

        #expect(!client.resolvePendingActionCall(result))

        let received = try await client.waitForActionCallResult(
            requestID: requestID,
            timeoutSeconds: 0.1
        )

        #expect(received.requestID == requestID)
        #expect(received.content == [.text("ok")])
    }

    @Test("early action-call acknowledgement is cached until the caller waits for it")
    func earlyActionCallAcknowledgementIsCached() async throws {
        let requestID = UUID(uuidString: "60000000-0000-0000-0000-000000000000")!
        let contextID = UUID(uuidString: "70000000-0000-0000-0000-000000000000")!
        let callerNodeID = UUID(uuidString: "80000000-0000-0000-0000-000000000000")!
        let targetNodeID = UUID(uuidString: "90000000-0000-0000-0000-000000000000")!
        let actionID = UUID(uuidString: "A0000000-0000-0000-0000-000000000000")!
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: contextID,
                node: callerNodeID
            ),
            localStore: KeepTalkingInMemoryStore()
        )
        let acknowledgement = KeepTalkingRequestAck(
            requestID: requestID,
            contextID: contextID,
            callerNodeID: callerNodeID,
            targetNodeID: targetNodeID,
            kind: .actionCall,
            state: .received,
            actionID: actionID,
            message: "Received by target node."
        )

        #expect(!client.resolvePendingActionCallAcknowledgement(acknowledgement))

        let received = try await client.waitForActionCallAcknowledgement(
            requestID: requestID,
            timeoutSeconds: 0.1
        )

        #expect(received?.requestID == requestID)
        #expect(received?.state == .received)
        #expect(received?.actionID == actionID)
    }

    @Test("incoming remote action call creates a placeholder context when missing")
    func incomingRemoteActionCallCreatesPlaceholderContext() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let selfNodeID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let callerNodeID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        let contextID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: contextID,
                node: selfNodeID
            ),
            primitiveActionCallback: { _, _ in
                KeepTalkingPrimitiveActionResponse(text: "opened")
            },
            localStore: localStore
        )

        let selfNode = KeepTalkingNode(id: selfNodeID)
        let callerNode = KeepTalkingNode(id: callerNodeID)
        try await selfNode.save(on: localStore.database)
        try await callerNode.save(on: localStore.database)

        let relation = try KeepTalkingNodeRelation(
            from: selfNode,
            to: callerNode,
            relationship: .trusted([KeepTalkingContext(id: contextID)])
        )
        try await relation.save(on: localStore.database)

        let bundle = KeepTalkingPrimitiveBundle(
            name: "open-url-in-browser",
            indexDescription: "Open a URL",
            action: .openURLInBrowser
        )
        let action = KeepTalkingAction(
            payload: .primitive(bundle),
            remoteAuthorisable: false,
            blockingAuthorisation: false
        )
        action.$node.id = selfNodeID
        try await action.save(on: localStore.database)

        let approval = try KeepTalkingNodeRelationActionRelation(
            relation: relation,
            action: action,
            approvingContext: .contexts([KeepTalkingContext(id: contextID)])
        )
        try await approval.save(on: localStore.database)

        let request = KeepTalkingActionCallRequest(
            contextID: contextID,
            callerNodeID: callerNodeID,
            targetNodeID: selfNodeID,
            call: KeepTalkingActionCall(
                action: try #require(action.id),
                arguments: [
                    "url": .string("https://example.com")
                ],
                metadata: .init()
            )
        )

        await #expect(throws: KeepTalkingClientError.self) {
            try await client.handleIncomingActionCallRequest(request)
        }

        let storedContext = try await KeepTalkingContext.query(
            on: localStore.database
        )
        .filter(\.$id, .equal, contextID)
        .first()

        #expect(storedContext?.id == contextID)
    }
}
