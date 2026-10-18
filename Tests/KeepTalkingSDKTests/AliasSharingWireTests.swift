import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

/// Shared aliases on the wire: the scoped one through context sync to every
/// member, the global one in node status to trusted members only, each
/// kept on arrival as a suggestion — and its avatar pulled like any blob.
struct AliasSharingWireTests {
    private struct Node {
        let store: KeepTalkingInMemoryStore
        let client: KeepTalkingClient
        let nodeID: UUID
        var database: any Database { store.database }
    }

    private let contextID = UUID()

    // MARK: - Scoped, through context sync

    @Test("a scoped alias reaches members by push and on the summary exchange, both ways")
    func scopedAliasReachesMembers() async throws {
        let alice = try await makeNode()
        let bob = try await makeNode()
        try await know([alice, bob])
        try await KeepTalkingClient.setAlias(
            "Ada", for: .node(alice.nodeID), scopeContextID: contextID, on: alice.database)

        let push = try await alice.client.ownAliasPush()
        #expect(push.alias.name == "Ada")
        #expect(push.alias.contextID == contextID)
        try await bob.client.handleIncomingContextSyncEnvelope(.aliasPush(push))
        #expect(try await suggestion(on: bob, from: alice, in: contextID)?.alias.name == "Ada")
        #expect(try await suggestion(on: bob, from: alice, in: nil) == nil)

        // The summary exchange carries the requester's alias up and the
        // responder's back.
        try await KeepTalkingClient.setAlias(
            "Bea", for: .node(bob.nodeID), scopeContextID: contextID, on: bob.database)
        try await KeepTalkingClient.setAlias(
            "Adeline", for: .node(alice.nodeID), scopeContextID: contextID, on: alice.database)
        let result = try await alice.client.executeContextSyncSummaryRequest(
            KeepTalkingContextSyncSummaryRequest(
                context: contextID,
                requester: bob.nodeID,
                recipient: alice.nodeID,
                alias: try await bob.client.ownScopedAlias()
            )
        )
        #expect(result.alias?.name == "Adeline")
        #expect(try await suggestion(on: alice, from: bob, in: contextID)?.alias.name == "Bea")

        try await bob.client.absorbSummarySets(result, pages: pages(from: alice))
        #expect(try await suggestion(on: bob, from: alice, in: contextID)?.alias.name == "Adeline")
        await shutdown([alice, bob])
    }

    @Test("not sharing the scoped alias here sends an empty one, which clears it")
    func scopedSharingOffClears() async throws {
        let alice = try await makeNode()
        let bob = try await makeNode()
        try await know([alice, bob])
        try await KeepTalkingClient.setAlias(
            "Ada", for: .node(alice.nodeID), scopeContextID: contextID, on: alice.database)
        try await bob.client.handleIncomingContextSyncEnvelope(.aliasPush(try await alice.client.ownAliasPush()))
        #expect(try await suggestion(on: bob, from: alice, in: contextID) != nil)

        try await KeepTalkingClient.setAliasShared(
            false, .scoped, in: contextID, localNodeID: alice.nodeID, on: alice.database)
        let push = try await alice.client.ownAliasPush()
        #expect(push.alias.isEmpty)
        try await bob.client.handleIncomingContextSyncEnvelope(.aliasPush(push))
        #expect(try await suggestion(on: bob, from: alice, in: contextID) == nil)
        await shutdown([alice, bob])
    }

    // MARK: - Global, in node status

    @Test("the global alias rides node status only to recipients trusted here, where it's shared")
    func globalAliasOnlyToTrusted() async throws {
        let alice = try await makeNode()
        let bob = UUID()
        let carol = UUID()
        try await saveNodes([bob, carol], on: alice.database)
        try await relate(alice.nodeID, to: bob, .trusted([KeepTalkingContext(id: contextID)]), on: alice.database)
        try await relate(alice.nodeID, to: carol, .pending, on: alice.database)
        try await KeepTalkingClient.setAlias("Ada", for: .node(alice.nodeID), on: alice.database)

        let toBob = try await status(from: alice, to: bob)
        #expect(toBob.alias?.name == "Ada")
        #expect(toBob.alias?.contextID == nil)
        #expect(toBob.alias?.revision == toBob.revision)
        #expect(try await status(from: alice, to: carol).alias == nil)

        // Not shared in this context: nothing said, so nothing cleared.
        try await KeepTalkingClient.setAliasShared(
            false, .global, in: contextID, localNodeID: alice.nodeID, on: alice.database)
        #expect(try await status(from: alice, to: bob).alias == nil)
        await shutdown([alice])
    }

    @Test("a status's global alias is kept only sealed, and from a node the user trusts")
    func globalAliasNeedsSealAndTrust() async throws {
        let alice = try await makeNode()
        let bob = try await makeNode()
        let carol = try await makeNode()
        try await know([alice, bob, carol])
        let context = KeepTalkingContext(id: contextID)
        for recipient in [bob, carol] {
            try await relate(alice.nodeID, to: recipient.nodeID, .trusted([context]), on: alice.database)
        }
        try await relate(bob.nodeID, to: alice.nodeID, .trusted([context]), on: bob.database)
        try await KeepTalkingClient.setAlias("Ada", for: .node(alice.nodeID), on: alice.database)

        try await bob.client.mergeDiscoveredNodeStatus(try await status(from: alice, to: bob.nodeID))
        #expect(try await suggestion(on: bob, from: alice, in: nil) == nil)

        try await bob.client.mergeDiscoveredNodeStatus(try await status(from: alice, to: bob.nodeID), sealed: true)
        #expect(try await suggestion(on: bob, from: alice, in: nil)?.alias.name == "Ada")

        // Carol doesn't trust Alice back.
        try await carol.client.mergeDiscoveredNodeStatus(try await status(from: alice, to: carol.nodeID), sealed: true)
        #expect(try await suggestion(on: carol, from: alice, in: nil) == nil)
        await shutdown([alice, bob, carol])
    }

    @Test("once the global alias is gone, an empty one goes out and clears it")
    func deletedGlobalAliasClears() async throws {
        let alice = try await makeNode()
        let bob = try await makeNode()
        try await know([alice, bob])
        let context = KeepTalkingContext(id: contextID)
        try await relate(alice.nodeID, to: bob.nodeID, .trusted([context]), on: alice.database)
        try await relate(bob.nodeID, to: alice.nodeID, .trusted([context]), on: bob.database)
        try await KeepTalkingClient.setAlias("Ada", for: .node(alice.nodeID), on: alice.database)
        try await bob.client.mergeDiscoveredNodeStatus(try await status(from: alice, to: bob.nodeID), sealed: true)
        #expect(try await suggestion(on: bob, from: alice, in: nil) != nil)

        try await KeepTalkingClient.setAlias(nil, for: .node(alice.nodeID), on: alice.database)
        let cleared = try await status(from: alice, to: bob.nodeID)
        #expect(cleared.alias?.isEmpty == true)
        try await bob.client.mergeDiscoveredNodeStatus(cleared, sealed: true)
        #expect(try await suggestion(on: bob, from: alice, in: nil) == nil)
        await shutdown([alice, bob])
    }

    // MARK: - Avatars

    @Test("a shared avatar is asked for, offered by its holder and pulled")
    func avatarIsPulled() async throws {
        let aliceRoom = FakeMultiplexer()
        let bobRoom = FakeMultiplexer()
        let alice = try await makeNode(transport: aliceRoom.transport)
        let bob = try await makeNode(transport: bobRoom.transport)
        try await know([alice, bob])
        try await alice.client.connect()
        try await bob.client.connect()

        let avatar = Data("an avatar".utf8)
        let blobID = try await alice.client.storeBlob(avatar, mimeType: "image/png", pathExtension: "png")
        try await KeepTalkingClient.setAppearance(
            KeepTalkingMappingAppearance(avatar: .init(blobID: blobID)),
            for: .node(alice.nodeID),
            scopeContextID: contextID,
            on: alice.database,
            blobStore: alice.client.blobStore
        )

        let push = try await alice.client.ownAliasPush()
        #expect(push.alias.appearance?.avatar?.blobID == blobID)
        try await bob.client.handleIncomingContextSyncEnvelope(.aliasPush(push))
        #expect(try await bob.client.missingSuggestionAvatarBlobIDs() == [blobID])

        let wanted = try #require(
            blobEnvelopes(bobRoom).first {
                if case .wanted(let items) = $0.step { return items.contains(.attachment(blobID: blobID)) }
                return false
            })
        #expect(wanted.recipient == nil)

        // Alice holds it, so she offers it to Bob…
        await alice.client.handleBlobTransferEnvelope(wanted)
        let offer = try #require(
            blobEnvelopes(aliceRoom).first {
                if case .offer = $0.step { return $0.recipient == bob.nodeID }
                return false
            })
        #expect(offer.step == .offer([.init(item: .attachment(blobID: blobID), byteCount: avatar.count)]))

        // …and Bob pulls it from her.
        await bob.client.handleBlobTransferEnvelope(offer)
        #expect(
            blobEnvelopes(bobRoom).contains {
                guard $0.recipient == alice.nodeID, case .pull(.attachment(blobID: blobID), _) = $0.step
                else { return false }
                return true
            })

        alice.client.disconnect()
        bob.client.disconnect()
        await shutdown([alice, bob])
    }

    // MARK: - Helpers

    private func makeNode(transport: KeepTalkingTransport = .unavailable) async throws -> Node {
        let store = try await KeepTalkingInMemoryStore.make()
        try await KeepTalkingContext(id: contextID).save(on: store.database)
        let nodeID = UUID()
        try await KeepTalkingNode(id: nodeID).save(on: store.database)
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: nodeID),
            transport: transport,
            localStore: store
        )
        return Node(store: store, client: client, nodeID: nodeID)
    }

    /// Every node holds a row for every other, as after discovery.
    private func know(_ nodes: [Node]) async throws {
        for node in nodes {
            try await saveNodes(nodes.map(\.nodeID).filter { $0 != node.nodeID }, on: node.database)
        }
    }

    private func saveNodes(_ ids: [UUID], on database: any Database) async throws {
        for id in ids {
            try await KeepTalkingNode(id: id).save(on: database)
        }
    }

    private func relate(
        _ from: UUID,
        to: UUID,
        _ relationship: KeepTalkingRelationship,
        on database: any Database
    ) async throws {
        try await KeepTalkingNodeRelation(
            from: KeepTalkingNode(id: from),
            to: KeepTalkingNode(id: to),
            relationship: relationship
        ).save(on: database)
    }

    private func status(from node: Node, to recipient: UUID) async throws -> KeepTalkingNodeStatus {
        try await node.client.currentNodeStatus(
            context: KeepTalkingContext(id: contextID),
            recipientNodeID: recipient
        )
    }

    /// What `node` keeps of what `sender` shared, in exactly that scope.
    private func suggestion(on node: Node, from sender: Node, in scope: UUID?) async throws
        -> KeepTalkingAliasSuggestion?
    {
        try await KeepTalkingMapping.query(on: node.database)
            .filter(\.$node.$id == sender.nodeID)
            .filter(\.$kind, .equal, .alias)
            .filter(\.$scopeContext.$id == scope)
            .filter(\.$deletedAt == nil)
            .first()?
            .suggestion
    }

    private func pages(from responder: Node) -> KeepTalkingContextSyncSetPages {
        let client = responder.client
        return KeepTalkingContextSyncSetPages(
            sideNotes: { try await client.executeSideNotesPageRequest($0) },
            messageDeletions: { try await client.executeMessageDeletionsPageRequest($0) }
        )
    }

    private func blobEnvelopes(_ room: FakeMultiplexer) -> [KeepTalkingBlobTransferEnvelope] {
        room.all.flatMap(\.envelopes).compactMap { $0 as? KeepTalkingBlobTransferEnvelope }
    }

    private func shutdown(_ nodes: [Node]) async {
        for node in nodes { await node.store.shutdown() }
    }
}
