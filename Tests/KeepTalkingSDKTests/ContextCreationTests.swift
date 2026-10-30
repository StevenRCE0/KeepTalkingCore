import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

/// A context is created exactly once and required everywhere else: a second
/// creation is refused by name instead of quietly adopting the existing row,
/// and nothing on a client materialises a context it was never given.
struct ContextCreationTests {
    private static let rounds = 24
    private static let racers = 8

    @Test("a second creation of the same context is refused by name")
    func secondCreationIsRefused() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let contextID = UUID()
        let created = try await KeepTalkingClient.createContext(contextID: contextID, on: store.database)
        #expect(created.id == contextID)

        do {
            try await KeepTalkingClient.createContext(contextID: contextID, on: store.database)
            Issue.record("the second creation went through")
        } catch KeepTalkingClientError.contextAlreadyExists(let refused) {
            #expect(refused == contextID)
        }
        let count = try await KeepTalkingContext.query(on: store.database)
            .filter(\.$id == contextID)
            .count()
        #expect(count == 1)
        await store.shutdown()
    }

    @Test("concurrent creations of one context let exactly one through")
    func concurrentCreationsLetOneThrough() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        for _ in 0..<Self.rounds {
            let contextID = UUID()
            let created = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<Self.racers {
                    group.addTask {
                        do {
                            try await KeepTalkingClient.createContext(contextID: contextID, on: store.database)
                            return true
                        } catch KeepTalkingClientError.contextAlreadyExists(let refused) {
                            return refused == contextID ? false : true
                        }
                    }
                }
                return try await group.reduce(into: [Bool]()) { $0.append($1) }
            }
            #expect(created.filter { $0 }.count == 1)
            let count = try await KeepTalkingContext.query(on: store.database)
                .filter(\.$id == contextID)
                .count()
            #expect(count == 1)
        }
        await store.shutdown()
    }

    @Test("requiring a context this node does not have names it")
    func missingContextIsNamed() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let contextID = UUID()
        do {
            _ = try await KeepTalkingClient.requireContext(contextID, on: store.database)
            Issue.record("a missing context was handed back")
        } catch KeepTalkingClientError.missingContext(let missing) {
            #expect(missing == contextID)
        }
        await store.shutdown()
    }

    @Test("a secret is never stored for a context the client was not given")
    func secretNeedsTheRow() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let contextID = UUID()
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: UUID()),
            localStore: store
        )
        do {
            try await client.setGroupChatSecret(Data(repeating: 7, count: 32), for: contextID)
            Issue.record("a secret was stored for a context that does not exist")
        } catch KeepTalkingClientError.missingContext(let missing) {
            #expect(missing == contextID)
        }
        #expect(try await client.loadGroupChatSecret(for: contextID) == nil)
        await store.shutdown()
    }
}
