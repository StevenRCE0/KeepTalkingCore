import Crypto
import Foundation
import Testing

@testable import KeepTalkingSDK

/// The tool-hint arguments are sealed by the caller (the node running the main
/// agent) for the *host* (the node that owns/executes the action), and the row
/// replicates to everyone. Both ends must be able to reopen it; a third peer
/// must not. These tests exercise the genuinely cross-node path — two nodes,
/// two stores, two keychains — which the self→self round-trip never touches.
struct SealedCallParametersCrossNodeTests {
    private struct Peer {
        let node: KeepTalkingNode
        let id: UUID
        let store: any KeepTalkingLocalStore
        let keychain: KeepTalkingInMemoryKeychainStore
        let client: KeepTalkingClient
    }

    private static func makePeer(
        id: UUID,
        contextID: UUID,
        knownNodeIDs: [UUID]
    ) async throws -> Peer {
        let store = try await KeepTalkingInMemoryStore.make()
        let keychain = KeepTalkingInMemoryKeychainStore()
        let node = KeepTalkingNode(id: id)
        try await node.save(on: store.database)
        for other in knownNodeIDs where other != id {
            try await KeepTalkingNode(id: other).save(on: store.database)
        }
        try await KeepTalkingContext(id: contextID).save(on: store.database)
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: id),
            localStore: store,
            keychain: keychain
        )
        try await client.persistMyNode()
        return Peer(node: node, id: id, store: store, keychain: keychain, client: client)
    }

    /// Wires a full bidirectional trust + public-key exchange between two peers,
    /// exactly as a real handshake would leave both stores.
    private static func handshake(_ a: Peer, _ b: Peer) async throws {
        let aPub = try await KeepTalkingClient.trust(
            node: b.id, localNode: a.node, on: a.store.database, keychain: a.keychain
        )
        let bPub = try await KeepTalkingClient.trust(
            node: a.id, localNode: b.node, on: b.store.database, keychain: b.keychain
        )
        try await KeepTalkingClient.lure(
            node: b.id, publicKey: bPub, localNodeID: a.id, overwrite: true, on: a.store.database
        )
        try await KeepTalkingClient.lure(
            node: a.id, publicKey: aPub, localNodeID: b.id, overwrite: true, on: b.store.database
        )
    }

    @Test("a call's parameters seal for the host and reopen on the host node")
    func crossNodeParametersReopenOnHost() async throws {
        let contextID = UUID()
        let callerID = UUID()
        let hostID = UUID()
        let caller = try await Self.makePeer(
            id: callerID, contextID: contextID, knownNodeIDs: [hostID]
        )
        let host = try await Self.makePeer(
            id: hostID, contextID: contextID, knownNodeIDs: [callerID]
        )
        try await Self.handshake(caller, host)

        let parameters = ["command": "echo hello", "path": "/tmp/x"]
        let sealed = await caller.client.sealCallParameters(parameters, for: hostID)
        let payload = try #require(sealed, "caller must seal to the host")

        let openedOnCaller = await caller.client.openSealedCallParameters(payload)
        #expect(openedOnCaller == parameters, "the caller can reopen what it sealed")

        let openedOnHost = await host.client.openSealedCallParameters(payload)
        #expect(openedOnHost == parameters, "the host must be able to decrypt the parameters")
    }

    /// When the pair has more than one (host→caller) relation — each with its own
    /// keypair — and the caller sealed against a key that is not the host's newest,
    /// the host must still find the matching private key. The recipient path that
    /// only tries the newest local relation fails here while the caller (sender)
    /// path still succeeds: exactly the "caller can, host can't" asymmetry.
    @Test("the host reopens parameters sealed against a non-newest relation key")
    func crossNodeParametersReopenAcrossMultipleRelations() async throws {
        let contextID = UUID()
        let callerID = UUID()
        let hostID = UUID()
        let caller = try await Self.makePeer(
            id: callerID, contextID: contextID, knownNodeIDs: [hostID]
        )
        let host = try await Self.makePeer(
            id: hostID, contextID: contextID, knownNodeIDs: [callerID]
        )

        // Caller trusts host; host learns the caller's public key.
        let callerPub = try await KeepTalkingClient.trust(
            node: hostID, localNode: caller.node,
            on: caller.store.database, keychain: caller.keychain
        )
        try await KeepTalkingClient.lure(
            node: callerID, publicKey: callerPub, localNodeID: hostID,
            overwrite: true, on: host.store.database
        )

        // The host stands up TWO (host→caller) relations, each with its own key,
        // with explicit, well-separated creation times so "newest" is deterministic.
        func mintHostRelation(createdAt: Date) async throws -> String {
            let relation = try KeepTalkingNodeRelation(
                from: host.node, to: caller.node, relationship: .trustedInAllContext
            )
            try await relation.save(on: host.store.database)
            let relationID = try #require(relation.id)
            let priv = Curve25519.KeyAgreement.PrivateKey()
            let pub = Data(priv.publicKey.rawRepresentation).base64EncodedString()
            try await host.keychain.set(
                .nodeIdentityPriv(relationID: relationID), value: Data(priv.rawRepresentation)
            )
            let key = try KeepTalkingNodeIdentityKey(relation: relation, publicKey: pub)
            try await key.save(on: host.store.database)
            key.createdAt = createdAt
            try await key.save(on: host.store.database)
            return pub
        }
        let hostPubOld = try await mintHostRelation(createdAt: Date(timeIntervalSince1970: 1000))
        _ = try await mintHostRelation(createdAt: Date(timeIntervalSince1970: 2000))

        // The caller only knows the host's OLDER public key, so it seals against it.
        try await KeepTalkingClient.lure(
            node: hostID, publicKey: hostPubOld, localNodeID: callerID,
            overwrite: true, on: caller.store.database
        )

        let parameters = ["query": "weather in tokyo"]
        let sealed = await caller.client.sealCallParameters(parameters, for: hostID)
        let payload = try #require(sealed)

        let openedOnCaller = await caller.client.openSealedCallParameters(payload)
        #expect(openedOnCaller == parameters, "the caller reopens its own seal")

        let openedOnHost = await host.client.openSealedCallParameters(payload)
        #expect(openedOnHost == parameters, "the host must try every one of its relation keys")
    }
}
