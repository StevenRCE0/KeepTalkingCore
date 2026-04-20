import CryptoKit
import Foundation
import Testing

@testable import KeepTalkingSDK

struct LureTests {
    @Test("static lure creates pending relation and stores remote public key")
    func staticLureCreatesPendingRelation() async throws {
        let localStore = try await KeepTalkingInMemoryStore()
        let localNodeID = UUID()
        let remoteNodeID = UUID()

        try await KeepTalkingNode(id: localNodeID).save(on: localStore.database)

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

        try await KeepTalkingClient.lure(
            node: remoteNodeID,
            publicKey: publicKey,
            localNodeID: localNodeID,
            on: localStore.database
        )

        let relation = try #require(
            try await KeepTalkingNodeRelation.query(on: localStore.database)
                .filter(\.$from.$id, .equal, remoteNodeID)
                .filter(\.$to.$id, .equal, localNodeID)
                .first()
        )

        #expect(relation.relationship == .pending)

        let keys = try await relation.$identityKeys.get(on: localStore.database)
        #expect(keys.count == 1)
        #expect(keys.first?.publicKey == publicKey)
        #expect(keys.first?.privateKey?.isEmpty == true)
    }

    @Test("static lure does not duplicate pending identity keys")
    func staticLureIsIdempotent() async throws {
        let localStore = try await KeepTalkingInMemoryStore()
        let localNodeID = UUID()
        let remoteNodeID = UUID()

        try await KeepTalkingNode(id: localNodeID).save(on: localStore.database)

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

        try await KeepTalkingClient.lure(
            node: remoteNodeID,
            publicKey: publicKey,
            localNodeID: localNodeID,
            on: localStore.database
        )
        try await KeepTalkingClient.lure(
            node: remoteNodeID,
            publicKey: publicKey,
            localNodeID: localNodeID,
            on: localStore.database
        )

        let relation = try #require(
            try await KeepTalkingNodeRelation.query(on: localStore.database)
                .filter(\.$from.$id, .equal, remoteNodeID)
                .filter(\.$to.$id, .equal, localNodeID)
                .first()
        )

        let keys = try await relation.$identityKeys.get(on: localStore.database)
        #expect(keys.count == 1)
    }

    @Test("static lure rejects invalid public key")
    func staticLureRejectsInvalidKey() async throws {
        let localStore = try await KeepTalkingInMemoryStore()
        let localNodeID = UUID()

        try await KeepTalkingNode(id: localNodeID).save(on: localStore.database)

        do {
            try await KeepTalkingClient.lure(
                node: UUID(),
                publicKey: "not-a-valid-key",
                localNodeID: localNodeID,
                on: localStore.database
            )
            Issue.record("expected invalidStoredValue error")
        } catch let error as KeepTalkingKVServiceError {
            switch error {
                case .invalidStoredValue:
                    break
                default:
                    Issue.record("unexpected KeepTalkingKVServiceError: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("instance lure wrapper delegates to static implementation")
    func instanceLureWrapperWorks() async throws {
        let localStore = try await KeepTalkingInMemoryStore()
        let localNodeID = UUID()
        let remoteNodeID = UUID()

        try await KeepTalkingNode(id: localNodeID).save(on: localStore.database)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: UUID(),
                node: localNodeID
            ),
            localStore: localStore
        )

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

        try await client.lure(node: remoteNodeID, publicKey: publicKey)

        let relation = try #require(
            try await KeepTalkingNodeRelation.query(on: localStore.database)
                .filter(\.$from.$id, .equal, remoteNodeID)
                .filter(\.$to.$id, .equal, localNodeID)
                .first()
        )

        #expect(relation.relationship == .pending)
    }
}
