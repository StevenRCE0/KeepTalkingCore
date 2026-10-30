import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

/// A peer first seen is a row several callers bring into being at once. Each
/// round races a fresh id, many times, so a find-then-save would lose at least
/// one round to the primary key.
struct FindOrCreateTests {
    private static let rounds = 24
    private static let racers = 8

    @Test("concurrent findOrCreates of one new node share a single row with a seen time")
    func concurrentNodeEnsure() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        for _ in 0..<Self.rounds {
            let nodeID = UUID()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.racers {
                    group.addTask {
                        _ = try await KeepTalkingNode.findOrCreate(nodeID, on: store.database)
                    }
                }
                try await group.waitForAll()
            }
            let rows = try await KeepTalkingNode.query(on: store.database)
                .filter(\.$id == nodeID)
                .all()
            #expect(rows.count == 1)
            #expect(rows.first.map { Date().timeIntervalSince($0.lastSeenAt) < 60 } == true)
        }
        await store.shutdown()
    }
}
