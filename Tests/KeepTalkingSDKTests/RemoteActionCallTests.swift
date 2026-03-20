import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

struct RemoteActionCallTests {
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
