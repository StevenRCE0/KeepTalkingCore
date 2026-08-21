import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

/// Id-only projection.
///
/// Callers that resolve a name the agent typed, or diff id sets, need identity
/// and nothing else. `query(on:).all().compactMap(\.id)` would decode a whole
/// model per row — for a node that means its keys, relations, and JSON columns.
/// These pin that the projection returns the same ids the full load would.
struct IDProjectionTests {

    private func makeStore() async throws -> KeepTalkingInMemoryStore {
        try await KeepTalkingInMemoryStore.make()
    }

    @Test("projects exactly the ids that exist")
    func projectsEveryID() async throws {
        let store = try await makeStore()
        let ids = (0..<5).map { _ in UUID() }
        for id in ids { try await KeepTalkingNode(id: id).save(on: store.database) }

        let projected = try await KeepTalkingClient.allIDs(
            of: KeepTalkingNode.self, on: store.database)

        #expect(Set(projected) == Set(ids))
        #expect(projected.count == ids.count)
        await store.shutdown()
    }

    @Test("an empty table projects nothing rather than failing")
    func emptyTableProjectsEmpty() async throws {
        let store = try await makeStore()
        let projected = try await KeepTalkingClient.allIDs(
            of: KeepTalkingNode.self, on: store.database)
        #expect(projected.isEmpty)
        await store.shutdown()
    }

    @Test("the projection agrees with a full load")
    func agreesWithFullLoad() async throws {
        let store = try await makeStore()
        for _ in 0..<4 { try await KeepTalkingNode(id: UUID()).save(on: store.database) }

        let projected = try await KeepTalkingClient.allIDs(
            of: KeepTalkingNode.self, on: store.database)
        let loaded = try await KeepTalkingNode.query(on: store.database)
            .all()
            .compactMap(\.id)

        // Same answer, without decoding the rows to get it.
        #expect(Set(projected) == Set(loaded))
        await store.shutdown()
    }

    @Test("it is generic over models, not just nodes")
    func worksForOtherModels() async throws {
        let store = try await makeStore()
        let contextID = UUID()
        try await KeepTalkingContext(id: contextID).save(on: store.database)

        let projected = try await KeepTalkingClient.allIDs(
            of: KeepTalkingContext.self, on: store.database)

        #expect(projected == [contextID])
        await store.shutdown()
    }

    @Test("knownNodeIDs sees the nodes this client can resolve against")
    func knownNodeIDsMatchesTable() async throws {
        let store = try await makeStore()
        let selfID = UUID()
        let peerID = UUID()
        try await KeepTalkingNode(id: selfID).save(on: store.database)
        try await KeepTalkingNode(id: peerID).save(on: store.database)
        let context = KeepTalkingContext(id: UUID())
        try await context.save(on: store.database)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                contextID: try context.requireID(), node: selfID),
            localStore: store
        )
        let known = try await client.knownNodeIDs()

        #expect(Set(known) == Set([selfID, peerID]))
        // And those ids are exactly what a named node resolves against.
        #expect(
            UUIDFriendlyName.resolve(peerID.friendlyNameToken, among: known)
                == .resolved(peerID))
        await store.shutdown()
    }
}
