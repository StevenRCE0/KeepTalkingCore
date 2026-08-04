import Foundation
import Testing

@testable import KeepTalkingSDK

struct SealedCallParametersTests {
    /// A call that runs on this node seals to the self→self relation, so that
    /// relation has to carry an identity keypair. It didn't: the relation was
    /// created bare, `localKeyAgreementMaterials` threw
    /// `localIdentityPrivateKeyMissing`, and `sealCallParameters` swallowed it
    /// and returned nil — every local tool call published its hint row with the
    /// arguments silently dropped instead of sealed.
    @Test("a local call's parameters seal and reopen on this node")
    func localParametersRoundTrip() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let node = KeepTalkingNode(id: UUID())
        let context = KeepTalkingContext(id: UUID())
        try await node.save(on: store.database)
        try await context.save(on: store.database)
        let nodeID = try #require(node.id)
        let contextID = try #require(context.id)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: nodeID),
            localStore: store
        )

        // Connect-time bootstrap: this is what has to leave the local identity
        // relation usable, not merely present.
        try await client.persistMyNode()

        let parameters = ["command": "echo hello", "timeout": "30"]
        let sealed = await client.sealCallParameters(parameters, for: nil)
        let sealedPayload = try #require(
            sealed,
            "sealing to this node must produce ciphertext"
        )

        let opened = await client.openSealedCallParameters(sealedPayload)
        #expect(opened == parameters)
    }

    /// The keypair has to be minted for a relation that already exists, not just
    /// for one being created — every install that has already run holds the bare
    /// relation and would never be repaired otherwise.
    @Test("an existing keypair-less local relation is repaired")
    func existingLocalRelationGainsKeypair() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let node = KeepTalkingNode(id: UUID())
        let context = KeepTalkingContext(id: UUID())
        try await node.save(on: store.database)
        try await context.save(on: store.database)
        let nodeID = try #require(node.id)
        let contextID = try #require(context.id)

        // Stand up the pre-fix state: the self relation exists, with no keys.
        let bareRelation = try KeepTalkingNodeRelation(
            from: node,
            to: node,
            relationship: .owner
        )
        try await bareRelation.save(on: store.database)
        let relationID = try #require(bareRelation.id)
        let keysBefore = try await KeepTalkingNodeIdentityKey.query(on: store.database)
            .filter(\.$relation.$id, .equal, relationID)
            .count()
        #expect(keysBefore == 0)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: nodeID),
            localStore: store
        )
        try await client.persistMyNode()

        let keysAfter = try await KeepTalkingNodeIdentityKey.query(on: store.database)
            .filter(\.$relation.$id, .equal, relationID)
            .count()
        #expect(keysAfter == 1)

        let sealed = await client.sealCallParameters(["query": "weather"], for: nil)
        #expect(sealed != nil)
    }
}
