import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

struct MappingSuggestionTests {
    typealias Appearance = KeepTalkingMappingAppearance

    // MARK: - Receiving

    @Test("a shared alias becomes a pending suggestion, kept apart from the user's alias")
    func storesPendingSuggestion() async throws {
        try await withStore { database, _ in
            let peer = try await makeNode(on: database)
            try await KeepTalkingClient.applySharedAlias(
                shared(name: "Alice", revision: 10), from: peer, on: database)

            let resolution = try await lookup(on: database).resolve(.node(peer))
            #expect(resolution.alias == nil)
            #expect(resolution.suggestion?.name == "Alice")
            #expect(resolution.primary() == peer.friendlyName)

            let pending = try await KeepTalkingClient.pendingAliasSuggestions(scopeContextID: nil, on: database)
            #expect(pending.map(\.target) == [.node(peer)])
        }
    }

    @Test("older revisions and unchanged content are ignored; an empty alias clears")
    func revisionsAndClearing() async throws {
        try await withStore { database, _ in
            let peer = try await makeNode(on: database)
            #expect(
                try await KeepTalkingClient.applySharedAlias(
                    shared(name: "Alice", revision: 10), from: peer, on: database))
            #expect(
                !(try await KeepTalkingClient.applySharedAlias(
                    shared(name: "Old", revision: 5), from: peer, on: database)))

            try await KeepTalkingClient.ignoreAliasSuggestion(for: .node(peer), scopeContextID: nil, on: database)
            // A re-send with a newer revision but the same content stays reviewed.
            #expect(
                !(try await KeepTalkingClient.applySharedAlias(
                    shared(name: "Alice", revision: 20), from: peer, on: database)))
            #expect(try await KeepTalkingClient.pendingAliasSuggestions(scopeContextID: nil, on: database).isEmpty)

            #expect(
                try await KeepTalkingClient.applySharedAlias(shared(name: nil, revision: 30), from: peer, on: database))
            #expect(try await aliasRows(for: peer, on: database).isEmpty)
        }
    }

    @Test("a scoped suggestion overlays the global one in its context only")
    func scopedOverGlobal() async throws {
        try await withStore { database, _ in
            let peer = try await makeNode(on: database)
            let context = try await makeContext(on: database)
            try await KeepTalkingClient.applySharedAlias(
                shared(name: "Alice", appearance: Appearance(color: [.init("#111111")]), revision: 1),
                from: peer, on: database)
            try await KeepTalkingClient.applySharedAlias(
                shared(context: context, name: "Ally", revision: 1), from: peer, on: database)

            let lookup = try await lookup(on: database)
            let inContext = lookup.suggestion(for: .node(peer), in: context)
            #expect(inContext?.name == "Ally")
            #expect(inContext?.appearance?.color(for: .apple) == "#111111")
            #expect(lookup.suggestion(for: .node(peer))?.name == "Alice")
            #expect(lookup.scoped(to: context).resolve(.node(peer)).suggestion?.name == "Ally")
        }
    }

    @Test("a suggestion that matches the user's own alias arrives reviewed")
    func matchingOwnAliasArrivesReviewed() async throws {
        try await withStore { database, _ in
            let peer = try await makeNode(on: database)
            try await KeepTalkingClient.setAlias("Alice", for: .node(peer), on: database)
            try await KeepTalkingClient.applySharedAlias(shared(name: "alice", revision: 1), from: peer, on: database)
            #expect(try await KeepTalkingClient.pendingAliasSuggestions(scopeContextID: nil, on: database).isEmpty)
        }
    }

    // MARK: - Reviewing

    @Test("accepting copies the suggestion into the user's global alias; a later change is pending again")
    func acceptAdopts() async throws {
        try await withStore { database, _ in
            let peer = try await makeNode(on: database)
            let context = try await makeContext(on: database)
            let appearance = Appearance(icon: [.init(.emoji(value: "🦊"))])
            try await KeepTalkingClient.applySharedAlias(
                shared(context: context, name: "Alice", appearance: appearance, revision: 1),
                from: peer, on: database)

            try await KeepTalkingClient.acceptAliasSuggestion(for: .node(peer), scopeContextID: context, on: database)
            #expect(try await KeepTalkingClient.alias(for: .node(peer), on: database) == "Alice")
            #expect(try await KeepTalkingClient.appearance(for: .node(peer), on: database) == appearance)
            #expect(try await KeepTalkingClient.pendingAliasSuggestions(scopeContextID: context, on: database).isEmpty)

            try await KeepTalkingClient.applySharedAlias(
                shared(context: context, name: "Alicia", revision: 2), from: peer, on: database)
            #expect(
                try await KeepTalkingClient.pendingAliasSuggestions(scopeContextID: context, on: database).count == 1)
        }
    }

    @Test("accepting a global suggestion keeps it on the same row, reviewed")
    func acceptGlobalOnSameRow() async throws {
        try await withStore { database, _ in
            let peer = try await makeNode(on: database)
            try await KeepTalkingClient.applySharedAlias(shared(name: "Alice", revision: 1), from: peer, on: database)
            try await KeepTalkingClient.acceptAliasSuggestion(for: .node(peer), scopeContextID: nil, on: database)

            let rows = try await aliasRows(for: peer, on: database)
            #expect(rows.count == 1)
            #expect(rows.first?.value == "Alice")
            #expect(rows.first?.suggestion?.isPending == false)
        }
    }

    @Test("accept all and ignore all cover every pending suggestion in the scope")
    func acceptAllAndIgnoreAll() async throws {
        try await withStore { database, _ in
            let context = try await makeContext(on: database)
            let alice = try await makeNode(on: database)
            let bob = try await makeNode(on: database)
            try await KeepTalkingClient.applySharedAlias(
                shared(context: context, name: "Alice", revision: 1), from: alice, on: database)
            try await KeepTalkingClient.applySharedAlias(
                shared(context: context, name: "Bob", revision: 1), from: bob, on: database)

            try await KeepTalkingClient.ignoreAllAliasSuggestions(scopeContextID: context, on: database)
            #expect(try await KeepTalkingClient.pendingAliasSuggestions(scopeContextID: context, on: database).isEmpty)
            // Ignoring doesn't hide what they call themselves.
            #expect(try await lookup(on: database).suggestion(for: .node(alice), in: context)?.name == "Alice")

            try await KeepTalkingClient.applySharedAlias(
                shared(context: context, name: "Alicia", revision: 2), from: alice, on: database)
            try await KeepTalkingClient.applySharedAlias(
                shared(context: context, name: "Bobby", revision: 2), from: bob, on: database)
            try await KeepTalkingClient.acceptAllAliasSuggestions(scopeContextID: context, on: database)
            #expect(try await KeepTalkingClient.alias(for: .node(alice), on: database) == "Alicia")
            #expect(try await KeepTalkingClient.alias(for: .node(bob), on: database) == "Bobby")
        }
    }

    // MARK: - Row lifetime

    @Test("removing the user's name keeps a row that still holds a suggestion")
    func nameRemovalKeepsSuggestion() async throws {
        try await withStore { database, _ in
            let peer = try await makeNode(on: database)
            try await KeepTalkingClient.setAlias("Mum", for: .node(peer), on: database)
            try await KeepTalkingClient.applySharedAlias(shared(name: "Jane", revision: 1), from: peer, on: database)
            try await KeepTalkingClient.setAlias(nil, for: .node(peer), on: database)

            let rows = try await aliasRows(for: peer, on: database)
            #expect(rows.count == 1)
            #expect(rows.first?.value == "")
            #expect(rows.first?.suggestion?.alias.name == "Jane")
        }
    }

    // MARK: - Sharing the local alias

    @Test("sharing into contexts is recorded on the local node's global row")
    func sharingContexts() async throws {
        try await withStore { database, _ in
            let me = try await makeNode(on: database)
            let first = try await makeContext(on: database)
            let second = try await makeContext(on: database)

            try await KeepTalkingClient.setAliasShared(true, in: first, localNodeID: me, on: database)
            try await KeepTalkingClient.setAliasShared(true, in: second, localNodeID: me, on: database)
            #expect(try await KeepTalkingClient.aliasSharedContexts(localNodeID: me, on: database) == [first, second])
            // Sharing alone gives no name.
            #expect(try await KeepTalkingClient.alias(for: .node(me), on: database) == nil)

            try await KeepTalkingClient.setAliasShared(false, in: first, localNodeID: me, on: database)
            try await KeepTalkingClient.setAliasShared(false, in: second, localNodeID: me, on: database)
            #expect(try await KeepTalkingClient.aliasSharedContexts(localNodeID: me, on: database).isEmpty)
            #expect(try await aliasRows(for: me, on: database).isEmpty)
        }
    }

    // MARK: - Blobs

    @Test("a suggested avatar survives a sweep, and a replaced one is pruned")
    func suggestedAvatarBlobs() async throws {
        try await withStore { database, blobStore in
            let peer = try await makeNode(on: database)
            let first = try await KeepTalkingClient.storeBlob(
                Data("first".utf8), mimeType: "image/png", on: database, blobStore: blobStore)
            try await KeepTalkingClient.applySharedAlias(
                shared(appearance: Appearance(avatar: .init(blobID: first)), revision: 1),
                from: peer, on: database, blobStore: blobStore)
            #expect(try await KeepTalkingClient.pruneAllStrayBlobs(on: database, blobStore: blobStore).isEmpty)

            let second = try await KeepTalkingClient.storeBlob(
                Data("second".utf8), mimeType: "image/png", on: database, blobStore: blobStore)
            try await KeepTalkingClient.applySharedAlias(
                shared(appearance: Appearance(avatar: .init(blobID: second)), revision: 2),
                from: peer, on: database, blobStore: blobStore)
            #expect(try await blobRecordIDs(on: database) == [second])
        }
    }

    // MARK: - Helpers

    private func shared(
        context: UUID? = nil,
        name: String? = nil,
        appearance: Appearance? = nil,
        revision: UInt64
    ) -> KeepTalkingSharedAlias {
        KeepTalkingSharedAlias(contextID: context, name: name, appearance: appearance, revision: revision)
    }

    /// Keeps the store alive for the whole body and shuts it down after — a
    /// store released with its connection open trips SQLite's deinit check.
    private func withStore(
        _ body: (any Database, KeepTalkingBlobStore) async throws -> Void
    ) async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappingSuggestionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }
        do {
            try await body(localStore.database, KeepTalkingBlobStore(baseURL: baseURL))
        } catch {
            await localStore.shutdown()
            throw error
        }
        await localStore.shutdown()
    }

    private func makeNode(on database: any Database) async throws -> UUID {
        let node = KeepTalkingNode(id: UUID())
        try await node.save(on: database)
        return try #require(node.id)
    }

    private func makeContext(on database: any Database) async throws -> UUID {
        let context = KeepTalkingContext(id: UUID())
        try await context.save(on: database)
        return try #require(context.id)
    }

    private func lookup(on database: any Database) async throws -> KeepTalkingAliasLookup {
        KeepTalkingClient.aliasLookup(mappings: try await KeepTalkingMapping.query(on: database).all())
    }

    private func aliasRows(for node: UUID, on database: any Database) async throws -> [KeepTalkingMapping] {
        try await KeepTalkingMapping.query(on: database)
            .filter(\.$node.$id == node)
            .filter(\.$kind, .equal, .alias)
            .filter(\.$deletedAt == nil)
            .all()
    }

    private func blobRecordIDs(on database: any Database) async throws -> Set<String> {
        Set(try await KeepTalkingBlobRecord.query(on: database).all(\.$id).compactMap { $0 })
    }
}
