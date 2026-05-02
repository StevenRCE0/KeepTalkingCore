import AIProxy
import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

struct RemoteActionCallTests {
    @Test("incoming node status stores grants on an existing trusted local-to-remote relation")
    func incomingNodeStatusStoresGrantOnExistingTrustedLocalToRemoteRelation()
        async throws
    {
        let localStore = KeepTalkingInMemoryStore()
        let localNodeID = UUID(uuidString: "AAAAAAA1-0000-0000-0000-000000000001")!
        let remoteNodeID = UUID(uuidString: "BBBBBBB2-0000-0000-0000-000000000002")!
        let contextID = UUID(uuidString: "CCCCCCC3-0000-0000-0000-000000000003")!
        let actionID = UUID(uuidString: "DDDDDDD4-0000-0000-0000-000000000004")!

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: contextID,
                node: localNodeID
            ),
            localStore: localStore
        )

        let localNode = KeepTalkingNode(id: localNodeID)
        let remoteNode = KeepTalkingNode(id: remoteNodeID)
        try await localNode.save(on: localStore.database)
        try await remoteNode.save(on: localStore.database)

        let context = KeepTalkingContext(id: contextID)
        try await context.save(on: localStore.database)
        let relation = try KeepTalkingNodeRelation(
            from: localNode,
            to: remoteNode,
            relationship: .trusted([context])
        )
        try await relation.save(on: localStore.database)

        let reverseRelation = try KeepTalkingNodeRelation(
            from: remoteNode,
            to: localNode,
            relationship: .trusted([context])
        )
        try await reverseRelation.save(on: localStore.database)

        let status = KeepTalkingNodeStatus(
            node: KeepTalkingNode(id: remoteNodeID),
            contextID: try #require(context.id),
            nodeRelations: [
                KeepTalkingNodeRelationStatus(
                    toNodeID: localNodeID,
                    relationship: .trusted([context]),
                    actions: [
                        KeepTalkingAdvertisedAction(
                            actionID: actionID,
                            ownerNodeID: remoteNodeID,
                            descriptor: KeepTalkingActionDescriptor(
                                subject: nil,
                                action: KeepTalkingActionWithDescription(
                                    description: "Open a URL"
                                ),
                                object: nil
                            ),
                            payloadSummary: .primitive(
                                name: "open-url-in-browser",
                                indexDescription: "Open a URL",
                                action: .openURLInBrowser
                            ),
                            remoteAuthorisable: false,
                            blockingAuthorisation: false,
                            availability: .notApplicable
                        )
                    ]
                )
            ]
        )

        try await client.mergeDiscoveredNodeStatus(status)

        let mergedRelation = try await KeepTalkingNodeRelation.query(
            on: localStore.database
        )
        .filter(\.$from.$id, .equal, localNodeID)
        .filter(\.$to.$id, .equal, remoteNodeID)
        .first()
        let action = try await KeepTalkingAction.find(actionID, on: localStore.database)
        let isGranted = try await KeepTalkingClient.isActionGrantedToNode(
            node: localNode,
            action: try #require(action),
            context: context,
            selfNode: localNode,
            on: localStore.database
        )

        #expect(mergedRelation?.id == relation.id)
        #expect(isGranted)
    }

    @Test("incoming node status ignores grants outside the local trust scope")
    func incomingNodeStatusIgnoresGrantOutsideLocalTrustScope() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let localNodeID = UUID(uuidString: "AAAAAAA1-9999-9999-9999-999999999999")!
        let remoteNodeID = UUID(uuidString: "BBBBBBB2-8888-8888-8888-888888888888")!
        let grantedContextID = UUID(uuidString: "CCCCCCC3-7777-7777-7777-777777777777")!
        let trustedContextID = UUID(uuidString: "DDDDDDD4-6666-6666-6666-666666666666")!
        let actionID = UUID(uuidString: "EEEEEEE5-5555-5555-5555-555555555555")!

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: grantedContextID,
                node: localNodeID
            ),
            localStore: localStore
        )

        let localNode = KeepTalkingNode(id: localNodeID)
        let remoteNode = KeepTalkingNode(id: remoteNodeID)
        let grantedContext = KeepTalkingContext(id: grantedContextID)
        let trustedContext = KeepTalkingContext(id: trustedContextID)

        try await localNode.save(on: localStore.database)
        try await remoteNode.save(on: localStore.database)
        try await grantedContext.save(on: localStore.database)
        try await trustedContext.save(on: localStore.database)

        let trustedRelation = try KeepTalkingNodeRelation(
            from: localNode,
            to: remoteNode,
            relationship: .trusted([trustedContext])
        )
        try await trustedRelation.save(on: localStore.database)

        let status = KeepTalkingNodeStatus(
            node: KeepTalkingNode(id: remoteNodeID),
            contextID: try #require(grantedContext.id),
            nodeRelations: [
                KeepTalkingNodeRelationStatus(
                    toNodeID: localNodeID,
                    relationship: .trusted([grantedContext]),
                    actions: [
                        KeepTalkingAdvertisedAction(
                            actionID: actionID,
                            ownerNodeID: remoteNodeID,
                            descriptor: KeepTalkingActionDescriptor(
                                subject: nil,
                                action: KeepTalkingActionWithDescription(
                                    description: "Open a URL"
                                ),
                                object: nil
                            ),
                            payloadSummary: .primitive(
                                name: "open-url-in-browser",
                                indexDescription: "Open a URL",
                                action: .openURLInBrowser
                            ),
                            remoteAuthorisable: false,
                            blockingAuthorisation: false,
                            availability: .notApplicable
                        )
                    ]
                )
            ]
        )

        try await client.mergeDiscoveredNodeStatus(status)

        let action = try await KeepTalkingAction.find(actionID, on: localStore.database)
        let actionLink = try await KeepTalkingNodeRelationActionRelation.query(
            on: localStore.database
        )
        .filter(\.$relation.$id, .equal, try #require(trustedRelation.id))
        .filter(\.$action.$id, .equal, actionID)
        .first()
        let isGranted = try await KeepTalkingClient.isActionGrantedToNode(
            node: localNode,
            action: try #require(action),
            context: grantedContext,
            selfNode: localNode,
            on: localStore.database
        )

        #expect(actionLink == nil)
        #expect(!isGranted)
    }

    @Test("grant action permission supports actions hosted on owned nodes")
    func grantActionPermissionSupportsOwnedHostNodes() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let ownerNodeID = UUID(uuidString: "AAAA1111-0000-0000-0000-000000000001")!
        let ownedHostNodeID = UUID(uuidString: "BBBB2222-0000-0000-0000-000000000002")!
        let targetNodeID = UUID(uuidString: "CCCC3333-0000-0000-0000-000000000003")!
        let contextID = UUID(uuidString: "DDDD4444-0000-0000-0000-000000000004")!

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: contextID,
                node: ownerNodeID
            ),
            localStore: localStore
        )

        let ownerNode = KeepTalkingNode(id: ownerNodeID)
        let ownedHostNode = KeepTalkingNode(id: ownedHostNodeID)
        let targetNode = KeepTalkingNode(id: targetNodeID)
        let context = KeepTalkingContext(id: contextID)

        try await ownerNode.save(on: localStore.database)
        try await ownedHostNode.save(on: localStore.database)
        try await targetNode.save(on: localStore.database)
        try await context.save(on: localStore.database)

        let ownershipRelation = try KeepTalkingNodeRelation(
            from: ownerNode,
            to: ownedHostNode,
            relationship: .owner
        )
        try await ownershipRelation.save(on: localStore.database)

        let targetRelation = try KeepTalkingNodeRelation(
            from: ownedHostNode,
            to: targetNode,
            relationship: .trustedInAllContext
        )
        try await targetRelation.save(on: localStore.database)

        let action = try await KeepTalkingClient.registerAction(
            payload: .primitive(
                KeepTalkingPrimitiveBundle(
                    name: "open-url-in-browser",
                    indexDescription: "Open a URL",
                    action: .openURLInBrowser
                )
            ),
            node: ownedHostNode,
            on: localStore.database
        )

        try await client.grantActionPermission(
            actionID: try #require(action.id),
            toNodeID: targetNodeID,
            scope: .context(context)
        )

        let approval =
            try await KeepTalkingNodeRelationActionRelation
            .query(on: localStore.database)
            .filter(\.$relation.$id, .equal, try #require(targetRelation.id))
            .filter(\.$action.$id, .equal, try #require(action.id))
            .first()

        #expect(approval != nil)
        #expect(approval?.applicable(in: context) == true)
    }

    @Test("incoming node status stores grants on the advertised action owner relation")
    func incomingNodeStatusStoresGrantOnAdvertisedActionOwnerRelation()
        async throws
    {
        let localStore = KeepTalkingInMemoryStore()
        let localNodeID = UUID(uuidString: "AAAAAAA1-1111-1111-1111-111111111111")!
        let remoteNodeID = UUID(uuidString: "BBBBBBB2-2222-2222-2222-222222222222")!
        let ownedHostNodeID = remoteNodeID
        let contextID = UUID(uuidString: "DDDDDDD4-4444-4444-4444-444444444444")!
        let actionID = UUID(uuidString: "EEEEEEE5-5555-5555-5555-555555555555")!

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: contextID,
                node: localNodeID
            ),
            localStore: localStore
        )

        let localNode = KeepTalkingNode(id: localNodeID)
        let remoteNode = KeepTalkingNode(id: remoteNodeID)
        let context = KeepTalkingContext(id: contextID)

        try await localNode.save(on: localStore.database)
        try await remoteNode.save(on: localStore.database)
        try await context.save(on: localStore.database)

        let trustedRemoteRelation = try KeepTalkingNodeRelation(
            from: localNode,
            to: remoteNode,
            relationship: .trusted([context])
        )
        try await trustedRemoteRelation.save(on: localStore.database)

        let reverseRelation = try KeepTalkingNodeRelation(
            from: remoteNode,
            to: localNode,
            relationship: .trusted([context])
        )
        try await reverseRelation.save(on: localStore.database)

        let status = KeepTalkingNodeStatus(
            node: KeepTalkingNode(id: remoteNodeID),
            contextID: try #require(context.id),
            nodeRelations: [
                KeepTalkingNodeRelationStatus(
                    toNodeID: localNodeID,
                    relationship: .trusted([context]),
                    actions: [
                        KeepTalkingAdvertisedAction(
                            actionID: actionID,
                            ownerNodeID: ownedHostNodeID,
                            descriptor: KeepTalkingActionDescriptor(
                                subject: nil,
                                action: KeepTalkingActionWithDescription(
                                    description: "Open a URL"
                                ),
                                object: nil
                            ),
                            payloadSummary: .primitive(
                                name: "open-url-in-browser",
                                indexDescription: "Open a URL",
                                action: .openURLInBrowser
                            ),
                            remoteAuthorisable: false,
                            blockingAuthorisation: false,
                            availability: .notApplicable
                        )
                    ]
                )
            ]
        )

        try await client.mergeDiscoveredNodeStatus(status)

        let action = try await KeepTalkingAction.find(actionID, on: localStore.database)
        let mergedLink = try await KeepTalkingNodeRelationActionRelation.query(
            on: localStore.database
        )
        .filter(\.$relation.$id, .equal, try #require(reverseRelation.id))
        .filter(\.$action.$id, .equal, actionID)
        .first()
        let isGranted = try await KeepTalkingClient.isActionGrantedToNode(
            node: localNode,
            action: try #require(action),
            context: context,
            selfNode: localNode,
            on: localStore.database
        )

        #expect(mergedLink != nil)
        #expect(isGranted)
    }

    @Test("action authorization is scoped to the relation target node")
    func actionAuthorizationIsScopedToRelationTargetNode() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let ownerNode = KeepTalkingNode(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
        )
        let grantedNode = KeepTalkingNode(
            id: UUID(uuidString: "22222222-0000-0000-0000-000000000002")!
        )
        let otherNode = KeepTalkingNode(
            id: UUID(uuidString: "33333333-0000-0000-0000-000000000003")!
        )
        let context = KeepTalkingContext(
            id: UUID(uuidString: "44444444-0000-0000-0000-000000000004")!
        )

        try await ownerNode.save(on: localStore.database)
        try await grantedNode.save(on: localStore.database)
        try await otherNode.save(on: localStore.database)
        try await context.save(on: localStore.database)

        let grantedRelation = try KeepTalkingNodeRelation(
            from: ownerNode,
            to: grantedNode,
            relationship: .trusted([context])
        )
        try await grantedRelation.save(on: localStore.database)

        let otherRelation = try KeepTalkingNodeRelation(
            from: ownerNode,
            to: otherNode,
            relationship: .trusted([context])
        )
        try await otherRelation.save(on: localStore.database)

        let action = try await KeepTalkingClient.registerAction(
            payload: .primitive(
                KeepTalkingPrimitiveBundle(
                    name: "open-url-in-browser",
                    indexDescription: "Open a URL",
                    action: .openURLInBrowser
                )
            ),
            node: ownerNode,
            on: localStore.database
        )

        let approval = try KeepTalkingNodeRelationActionRelation(
            relation: grantedRelation,
            action: action,
            approvingContext: .contexts([context])
        )
        try await approval.save(on: localStore.database)

        let grantedAuthorized =
            try await KeepTalkingClient.isActionGrantedToNode(
                node: grantedNode,
                action: action,
                context: context,
                selfNode: ownerNode,
                on: localStore.database
            )
        let otherAuthorized =
            try await KeepTalkingClient.isActionGrantedToNode(
                node: otherNode,
                action: action,
                context: context,
                selfNode: ownerNode,
                on: localStore.database
            )

        #expect(grantedAuthorized)
        #expect(!otherAuthorized)
    }

    @Test("action authorization prefers a trusted relation over a stale pending relation")
    func actionAuthorizationPrefersTrustedRelationOverPendingRelation()
        async throws
    {
        let localStore = KeepTalkingInMemoryStore()
        let ownerNode = KeepTalkingNode(
            id: UUID(uuidString: "55555555-0000-0000-0000-000000000001")!
        )
        let targetNode = KeepTalkingNode(
            id: UUID(uuidString: "66666666-0000-0000-0000-000000000002")!
        )
        let context = KeepTalkingContext(
            id: UUID(uuidString: "77777777-0000-0000-0000-000000000003")!
        )

        try await ownerNode.save(on: localStore.database)
        try await targetNode.save(on: localStore.database)
        try await context.save(on: localStore.database)

        let pendingRelation = try KeepTalkingNodeRelation(
            from: ownerNode,
            to: targetNode,
            relationship: .pending
        )
        try await pendingRelation.save(on: localStore.database)

        let trustedRelation = try KeepTalkingNodeRelation(
            from: ownerNode,
            to: targetNode,
            relationship: .trusted([context])
        )
        try await trustedRelation.save(on: localStore.database)

        let action = try await KeepTalkingClient.registerAction(
            payload: .primitive(
                KeepTalkingPrimitiveBundle(
                    name: "open-url-in-browser",
                    indexDescription: "Open a URL",
                    action: .openURLInBrowser
                )
            ),
            node: ownerNode,
            on: localStore.database
        )

        let approval = try KeepTalkingNodeRelationActionRelation(
            relation: trustedRelation,
            action: action,
            approvingContext: .contexts([context])
        )
        try await approval.save(on: localStore.database)

        let isAuthorized = try await KeepTalkingClient.isActionGrantedToNode(
            node: targetNode,
            action: action,
            context: context,
            selfNode: ownerNode,
            on: localStore.database
        )

        #expect(isAuthorized)
    }

    @Test("grant action permission prefers a trusted relation over a stale pending relation")
    func grantActionPermissionPrefersTrustedRelationOverPendingRelation()
        async throws
    {
        let localStore = KeepTalkingInMemoryStore()
        let ownerNodeID = UUID(uuidString: "88888888-0000-0000-0000-000000000001")!
        let targetNodeID = UUID(uuidString: "99999999-0000-0000-0000-000000000002")!
        let contextID = UUID(uuidString: "AAAAAAA0-0000-0000-0000-000000000003")!

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: contextID,
                node: ownerNodeID
            ),
            localStore: localStore
        )

        let ownerNode = KeepTalkingNode(id: ownerNodeID)
        let targetNode = KeepTalkingNode(id: targetNodeID)
        let context = KeepTalkingContext(id: contextID)

        try await ownerNode.save(on: localStore.database)
        try await targetNode.save(on: localStore.database)
        try await context.save(on: localStore.database)

        let pendingRelation = try KeepTalkingNodeRelation(
            from: ownerNode,
            to: targetNode,
            relationship: .pending
        )
        try await pendingRelation.save(on: localStore.database)

        let trustedRelation = try KeepTalkingNodeRelation(
            from: ownerNode,
            to: targetNode,
            relationship: .trustedInAllContext
        )
        try await trustedRelation.save(on: localStore.database)

        let action = try await KeepTalkingClient.registerAction(
            payload: .primitive(
                KeepTalkingPrimitiveBundle(
                    name: "open-url-in-browser",
                    indexDescription: "Open a URL",
                    action: .openURLInBrowser
                )
            ),
            node: ownerNode,
            on: localStore.database
        )

        try await client.grantActionPermission(
            actionID: try #require(action.id),
            toNodeID: targetNodeID,
            scope: .context(context)
        )

        let trustedApproval =
            try await KeepTalkingNodeRelationActionRelation
            .query(on: localStore.database)
            .filter(\.$relation.$id, .equal, try #require(trustedRelation.id))
            .filter(\.$action.$id, .equal, try #require(action.id))
            .first()
        let pendingApproval =
            try await KeepTalkingNodeRelationActionRelation
            .query(on: localStore.database)
            .filter(\.$relation.$id, .equal, try #require(pendingRelation.id))
            .filter(\.$action.$id, .equal, try #require(action.id))
            .first()

        #expect(trustedApproval != nil)
        #expect(pendingApproval == nil)
    }

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
            content: [.text(text: "ok", annotations: nil, _meta: nil)]
        )

        #expect(!client.resolvePendingActionCall(result))

        let received = try await client.waitForActionCallResult(
            requestID: requestID,
            timeoutSeconds: 0.1
        )

        #expect(received.requestID == requestID)
        #expect(
            received.content
                == [.text(text: "ok", annotations: nil, _meta: nil)]
        )
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
            primitiveRegistry: KeepTalkingPrimitiveRegistry(
                toolParameters: { _ in ["type": AIProxyJSONValue.string("object")] },
                callAction: { _, _ in KeepTalkingPrimitiveActionResponse(text: "opened") }
            ),
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
        let action = try await KeepTalkingClient.registerAction(
            payload: .primitive(bundle),
            node: selfNode,
            on: localStore.database
        )

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
