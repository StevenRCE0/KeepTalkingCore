import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

/// A node pair's relation rows are created by whichever handler hears from
/// the peer first, and several hear at once. With no unique index on the
/// pair, only the write path can keep a race from adding a second row.
struct NodeRelationFirstOrCreateTests {
    private static let rounds = 24
    private static let racers = 8

    private func pair(on database: any Database) async throws -> (UUID, UUID) {
        let a = UUID()
        let b = UUID()
        try await KeepTalkingNode.findOrCreate(a, on: database)
        try await KeepTalkingNode.findOrCreate(b, on: database)
        return (a, b)
    }

    private func count(from: UUID, to: UUID, on database: any Database) async throws -> Int {
        try await KeepTalkingNodeRelation.query(on: database)
            .filter(\.$from.$id == from)
            .filter(\.$to.$id == to)
            .count()
    }

    @Test("concurrent firstOrCreates of one new pair leave a single row")
    func concurrentPairEnsure() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        for _ in 0..<Self.rounds {
            let (a, b) = try await pair(on: store.database)
            let ids = try await withThrowingTaskGroup(of: UUID?.self) { group in
                for _ in 0..<Self.racers {
                    group.addTask {
                        try await KeepTalkingNodeRelation.firstOrCreate(
                            from: a, to: b, initial: .pending, on: store.database
                        ).id
                    }
                }
                return try await group.reduce(into: [UUID?]()) { $0.append($1) }
            }
            #expect(Set(ids.compactMap { $0 }).count == 1)
            #expect(try await count(from: a, to: b, on: store.database) == 1)
        }
        await store.shutdown()
    }

    @Test("concurrent firstOrCreates of the self relation leave a single owner row")
    func concurrentSelfRelation() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        for _ in 0..<Self.rounds {
            let me = UUID()
            try await KeepTalkingNode.findOrCreate(me, on: store.database)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.racers {
                    group.addTask {
                        try await KeepTalkingNodeRelation.firstOrCreate(
                            from: me, to: me, initial: .owner, on: store.database
                        )
                    }
                }
                try await group.waitForAll()
            }
            let rows = try await KeepTalkingNodeRelation.rows(from: me, to: me, on: store.database)
            #expect(rows.count == 1)
            #expect(rows.first?.relationship == .owner)
        }
        await store.shutdown()
    }

    @Test("a pair that already holds several rows answers with the strongest, every time")
    func strongestRowWins() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let (a, b) = try await pair(on: store.database)
        try await KeepTalkingNodeRelation(fromID: a, toID: b, relationship: .pending)
            .save(on: store.database)
        try await KeepTalkingNodeRelation(fromID: a, toID: b, relationship: .trustedInAllContext)
            .save(on: store.database)
        try await KeepTalkingNodeRelation(fromID: a, toID: b, relationship: .preTrusted([]))
            .save(on: store.database)

        for _ in 0..<Self.rounds {
            let ensured = try await KeepTalkingNodeRelation.firstOrCreate(
                from: a, to: b, initial: .pending, on: store.database
            )
            #expect(ensured.relationship == .trustedInAllContext)
            let strongest = try await KeepTalkingNodeRelation.strongest(from: a, to: b, on: store.database)
            #expect(strongest?.id == ensured.id)
        }
        #expect(try await count(from: a, to: b, on: store.database) == 3)
        await store.shutdown()
    }

    @Test("an acceptance filter creates alongside rows it does not accept, once")
    func acceptanceCreatesOnce() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let (a, b) = try await pair(on: store.database)
        try await KeepTalkingNodeRelation(fromID: a, toID: b, relationship: .preTrusted([]))
            .save(on: store.database)

        let accepts: @Sendable (KeepTalkingRelationship) -> Bool = {
            $0.isTrustedOrOwner || $0 == .pending
        }
        let created = try await KeepTalkingNodeRelation.firstOrCreate(
            from: a, to: b, initial: .pending, accepting: accepts, on: store.database
        )
        #expect(created.relationship == .pending)
        #expect(try await count(from: a, to: b, on: store.database) == 2)

        let again = try await KeepTalkingNodeRelation.firstOrCreate(
            from: a, to: b, initial: .pending, accepting: accepts, on: store.database
        )
        #expect(again.id == created.id)
        #expect(try await count(from: a, to: b, on: store.database) == 2)
        await store.shutdown()
    }

    @Test("firstOrCreate runs inside a caller's transaction without opening another")
    func nestsInsideTransaction() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let (a, b) = try await pair(on: store.database)
        let id = try await store.database.transaction { db in
            try await KeepTalkingNodeRelation.firstOrCreate(
                from: a, to: b, initial: .pending, on: db
            ).id
        }
        #expect(id != nil)
        #expect(try await count(from: a, to: b, on: store.database) == 1)
        await store.shutdown()
    }
}
