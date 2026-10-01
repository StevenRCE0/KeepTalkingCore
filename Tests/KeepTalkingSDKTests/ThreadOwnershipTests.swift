import Foundation
import Testing

@testable import KeepTalkingSDK

/// The thread controller's keyed ownership and the context-carrying
/// `threadChanges` signal.
struct ThreadOwnershipTests {
    @Test("owningThread resolves by key and reports the narrowest thread")
    func owningThreadByKey() async throws {
        let (client, store, contextID, messages) = try await Self.fixture()
        let stored = KeepTalkingThread(
            context: KeepTalkingContext(id: contextID), startMessage: messages[0],
            endMessage: messages[2], state: .stored
        )
        let main = KeepTalkingThread(
            context: KeepTalkingContext(id: contextID), startMessage: messages[3],
            endMessage: nil, state: .contextMain
        )
        try await stored.save(on: store.database)
        try await main.save(on: store.database)

        #expect(try await client.owningThread(for: messages[1].id!, in: contextID)?.id == stored.id)
        #expect(try await client.owningThread(for: messages[2].id!, in: contextID)?.id == stored.id)
        #expect(try await client.owningThread(for: messages[5].id!, in: contextID)?.id == main.id)
        #expect(try await client.owningThread(for: UUID(), in: contextID) == nil)
        await store.shutdown()
    }

    @Test("setChitterChatter returns false for a row no thread holds")
    func setChitterChatterUnheld() async throws {
        let (client, store, contextID, messages) = try await Self.fixture()
        // No threads at all: nothing owns the row.
        #expect(try await client.setChitterChatter(messageID: messages[0].id!, in: contextID, marked: true) == false)
        await store.shutdown()
    }

    @Test("thread changes carry the context they happened in")
    func threadChangesCarryContext() async throws {
        let (client, store, contextID, messages) = try await Self.fixture()
        let thread = KeepTalkingThread(
            context: KeepTalkingContext(id: contextID), startMessage: messages[0],
            endMessage: nil, state: .contextMain
        )
        try await thread.save(on: store.database)
        let changes = SignalRecorder<UUID>()
        let subscription = client.threadChanges.observe { changes.record($0) }
        defer { subscription.cancel() }

        try await client.toggleChitterChatter(messageID: messages[1].id!, in: thread.id!)
        #expect(try await client.setChitterChatter(messageID: messages[2].id!, in: contextID, marked: true))
        try await client.archiveThread(thread.id!)
        await changes.waitForCount(3)

        #expect(changes.snapshot == [contextID, contextID, contextID])
        await store.shutdown()
    }

    private static func fixture() async throws -> (
        KeepTalkingClient, KeepTalkingInMemoryStore, UUID, [KeepTalkingContextMessage]
    ) {
        let store = try await KeepTalkingInMemoryStore.make()
        let contextID = UUID()
        try await KeepTalkingContext(id: contextID).save(on: store.database)
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: UUID()),
            localStore: store
        )
        await client.awaitStartupWork()
        var messages: [KeepTalkingContextMessage] = []
        for index in 0..<6 {
            let message = KeepTalkingContextMessage(
                id: UUID(), context: KeepTalkingContext(id: contextID),
                sender: .autonomous(name: "a"), content: "m\(index)",
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
            try await message.save(on: store.database)
            messages.append(message)
        }
        return (client, store, contextID, messages)
    }
}
