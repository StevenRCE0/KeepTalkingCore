import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

struct MappingAppearanceTests {
    typealias Appearance = KeepTalkingMappingAppearance

    // MARK: - Codec

    @Test("platforms are sorted and unique, so equal appearances encode identically")
    func canonicalEncoding() throws {
        let unknown = KeepTalkingPlatform(rawValue: "future-os")
        let a = Appearance(icon: [.init(.emoji(value: "🧪"), platforms: [.gtk, .apple, unknown])])
        let b = Appearance(icon: [.init(.emoji(value: "🧪"), platforms: [unknown, .apple, .gtk])])
        #expect(a == b)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(a)
        #expect(encoded == (try encoder.encode(b)))

        let decoded = try JSONDecoder().decode(Appearance.self, from: encoded)
        #expect(decoded == a)
        #expect(decoded.icon.first?.platforms == [.apple, unknown, .gtk])
    }

    @Test("an empty platform set means everywhere")
    func emptyPlatformsApplyEverywhere() {
        let variant = Appearance.Variant("#112233", platforms: [])
        #expect(variant.platforms == nil)
        #expect(variant.applies(to: .gtk))
    }

    // MARK: - Resolution

    @Test("first applicable variant wins, and SF Symbols render only on Apple")
    func platformResolution() {
        let appearance = Appearance(
            color: [.init("#000001", platforms: [.gtk]), .init("#000002")],
            icon: [.init(.sfSymbol(name: "flask.fill")), .init(.emoji(value: "🧪"))]
        )
        #expect(appearance.color(for: .gtk) == "#000001")
        #expect(appearance.color(for: .apple) == "#000002")
        #expect(appearance.icons(for: .apple) == [.sfSymbol(name: "flask.fill"), .emoji(value: "🧪")])
        #expect(appearance.icons(for: .gtk) == [.emoji(value: "🧪")])
    }

    @Test("overlaying fills each unset property from the base")
    func overlay() {
        let base = Appearance(
            color: [.init("#111111")],
            icon: [.init(.emoji(value: "🏠"))],
            avatar: .init(blobID: "base")
        )
        let scoped = Appearance(color: [.init("#222222")])
        let merged = scoped.overlaying(base)
        #expect(merged.color == [.init("#222222")])
        #expect(merged.icon == base.icon)
        #expect(merged.avatar == base.avatar)
    }

    // MARK: - Storage

    @Test("an appearance without a name makes a nameless alias row")
    func namelessAppearance() async throws {
        try await withStore { database, blobStore in
            let target = try await makeNodeTarget(on: database)
            let appearance = Appearance(color: [.init(" #ABCDEF ")])

            try await KeepTalkingClient.setAppearance(appearance, for: target, on: database)
            #expect(try await KeepTalkingClient.alias(for: target, on: database) == nil)
            #expect(
                try await KeepTalkingClient.appearance(for: target, on: database)
                    == Appearance(color: [.init("#ABCDEF")])
            )

            let lookup = KeepTalkingClient.aliasLookup(
                mappings: try await KeepTalkingMapping.query(on: database).all()
            )
            let resolution = lookup.resolve(target)
            #expect(resolution.alias == nil)
            #expect(resolution.appearance?.color(for: .apple) == "#ABCDEF")

            try await KeepTalkingClient.setAppearance(nil, for: target, on: database)
            #expect(try await liveAliasRows(for: target, on: database).isEmpty)
        }
    }

    @Test("removing the name keeps a row that still has an appearance")
    func removingNameKeepsFace() async throws {
        try await withStore { database, blobStore in
            let target = try await makeNodeTarget(on: database)

            try await KeepTalkingClient.setAlias("Mum", for: target, on: database)
            try await KeepTalkingClient.setAppearance(
                Appearance(icon: [.init(.emoji(value: "🌷"))]),
                for: target,
                on: database
            )
            try await KeepTalkingClient.setAlias(nil, for: target, on: database)

            let rows = try await liveAliasRows(for: target, on: database)
            #expect(rows.count == 1)
            #expect(rows.first?.value == "")
            #expect(rows.first?.appearance?.icon == [.init(.emoji(value: "🌷"))])

            // Clearing the appearance on a named row keeps the name.
            try await KeepTalkingClient.setAlias("Mum", for: target, on: database)
            try await KeepTalkingClient.setAppearance(nil, for: target, on: database)
            #expect(try await KeepTalkingClient.alias(for: target, on: database) == "Mum")
            #expect(try await KeepTalkingClient.appearance(for: target, on: database) == nil)
        }
    }

    @Test("an empty appearance is stored as none")
    func emptyStoredAsNil() async throws {
        try await withStore { database, blobStore in
            let target = try await makeNodeTarget(on: database)
            try await KeepTalkingClient.setAppearance(
                Appearance(color: [.init("   ")], icon: [.init(.emoji(value: ""))]),
                for: target,
                on: database
            )
            #expect(try await liveAliasRows(for: target, on: database).isEmpty)
        }
    }

    @Test("scoped appearances fall back to the global one per property")
    func scopedFallback() async throws {
        try await withStore { database, blobStore in
            let target = try await makeNodeTarget(on: database)
            let context = KeepTalkingContext(id: UUID())
            try await context.save(on: database)
            let contextID = try #require(context.id)

            try await KeepTalkingClient.setAppearance(
                Appearance(color: [.init("#111111")], icon: [.init(.emoji(value: "🏠"))]),
                for: target,
                on: database
            )
            try await KeepTalkingClient.setAppearance(
                Appearance(color: [.init("#222222")]),
                for: target,
                scopeContextID: contextID,
                on: database
            )

            let lookup = KeepTalkingClient.aliasLookup(
                mappings: try await KeepTalkingMapping.query(on: database).all()
            )
            let expected = Appearance(color: [.init("#222222")], icon: [.init(.emoji(value: "🏠"))])
            #expect(lookup.appearance(for: target, in: contextID) == expected)
            #expect(lookup.scoped(to: contextID).appearance(for: target) == expected)
            #expect(lookup.appearance(for: target)?.color(for: .apple) == "#111111")
        }
    }

    // MARK: - Blobs

    @Test("a stray-blob sweep keeps avatars and drops one an avatar change released")
    func avatarBlobsSurviveSweep() async throws {
        try await withStore { database, blobStore in
            let target = try await makeNodeTarget(on: database)

            let first = try await KeepTalkingClient.storeBlob(
                Data("first".utf8), mimeType: "image/png", on: database, blobStore: blobStore)
            try await KeepTalkingClient.setAppearance(
                Appearance(avatar: .init(blobID: first)), for: target, on: database, blobStore: blobStore)
            #expect(try await KeepTalkingClient.pruneAllStrayBlobs(on: database, blobStore: blobStore).isEmpty)

            let second = try await KeepTalkingClient.storeBlob(
                Data("second".utf8), mimeType: "image/png", on: database, blobStore: blobStore)
            try await KeepTalkingClient.setAppearance(
                Appearance(avatar: .init(blobID: second)), for: target, on: database, blobStore: blobStore)
            #expect(try await blobRecordIDs(on: database) == [second])

            try await KeepTalkingClient.setAppearance(nil, for: target, on: database, blobStore: blobStore)
            #expect(try await blobRecordIDs(on: database).isEmpty)
        }
    }

    @Test("a removed duplicate alias row releases its avatar")
    func softDeleteReleasesAvatar() async throws {
        try await withStore { database, blobStore in
            let target = try await makeNodeTarget(on: database)
            let blobID = try await KeepTalkingClient.storeBlob(
                Data("dup".utf8), mimeType: "image/png", on: database, blobStore: blobStore)

            // A second live alias row, as an older build or a merge could leave.
            let duplicate = KeepTalkingMapping(
                target: target,
                kind: .alias,
                value: "Old",
                appearance: Appearance(avatar: .init(blobID: blobID))
            )
            try await duplicate.save(on: database)
            try await KeepTalkingMapping(target: target, kind: .alias, value: "New").save(on: database)

            // Naming picks one live row; the other is soft-deleted with its face.
            try await KeepTalkingClient.setAlias("New", for: target, on: database, blobStore: blobStore)
            let all = try await KeepTalkingClient.mappings(for: target, includeDeleted: true, on: database)
            #expect(all.filter { $0.deletedAt != nil }.allSatisfy { $0.appearance == nil })
            let survivor = try #require(all.first { $0.deletedAt == nil })
            #expect(survivor.value == "New")
            if survivor.appearance == nil {
                #expect(try await blobRecordIDs(on: database).isEmpty)
            }
        }
    }

    @Test("deleting a context reports its mappings' avatars for pruning")
    func contextDeleteReportsAvatars() async throws {
        try await withStore { database, blobStore in
            let target = try await makeNodeTarget(on: database)
            let context = KeepTalkingContext(id: UUID())
            try await context.save(on: database)
            let contextID = try #require(context.id)

            let scoped = try await KeepTalkingClient.storeBlob(
                Data("scoped".utf8), mimeType: "image/png", on: database, blobStore: blobStore)
            let named = try await KeepTalkingClient.storeBlob(
                Data("named".utf8), mimeType: "image/png", on: database, blobStore: blobStore)
            try await KeepTalkingClient.setAppearance(
                Appearance(avatar: .init(blobID: scoped)), for: target, scopeContextID: contextID, on: database)
            try await KeepTalkingClient.setAppearance(
                Appearance(avatar: .init(blobID: named)), for: .context(contextID), on: database)

            let referenced = try await KeepTalkingClient.blobIDsReferenced(byContextID: contextID, on: database)
            #expect(referenced == [scoped, named])

            try await context.delete(on: database)
            let pruned = try await KeepTalkingClient.pruneStrayBlobs(
                among: referenced, on: database, blobStore: blobStore)
            #expect(Set(pruned) == [scoped, named])
        }
    }

    @Test("deleting a node locally prunes the avatar its alias held")
    func nodeDeletePrunesAvatar() async throws {
        try await withStore { database, blobStore in
            let target = try await makeNodeTarget(on: database)
            let blobID = try await KeepTalkingClient.storeBlob(
                Data("node".utf8), mimeType: "image/png", on: database, blobStore: blobStore)
            try await KeepTalkingClient.setAppearance(
                Appearance(avatar: .init(blobID: blobID)), for: target, on: database)

            try await KeepTalkingClient.deleteNodeLocally(
                target.id, localNodeID: UUID(), on: database, blobStore: blobStore)
            #expect(try await blobRecordIDs(on: database).isEmpty)
        }
    }

    // MARK: - Helpers

    /// Keeps the store alive for the whole body and shuts it down after — a
    /// store released with its connection open trips SQLite's deinit check.
    private func withStore(
        _ body: (any Database, KeepTalkingBlobStore) async throws -> Void
    ) async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappingAppearanceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }
        do {
            try await body(localStore.database, KeepTalkingBlobStore(baseURL: baseURL))
        } catch {
            await localStore.shutdown()
            throw error
        }
        await localStore.shutdown()
    }

    private func makeNodeTarget(on database: any Database) async throws -> KeepTalkingMappingTarget {
        let node = KeepTalkingNode(id: UUID())
        try await node.save(on: database)
        return .node(try #require(node.id))
    }

    private func liveAliasRows(
        for target: KeepTalkingMappingTarget,
        on database: any Database
    ) async throws -> [KeepTalkingMapping] {
        try await KeepTalkingClient.mappings(for: target, on: database).filter { $0.kind == .alias }
    }

    private func blobRecordIDs(on database: any Database) async throws -> Set<String> {
        Set(try await KeepTalkingBlobRecord.query(on: database).all(\.$id).compactMap { $0 })
    }
}
