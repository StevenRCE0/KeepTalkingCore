import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

struct BlobClaimTests {
    typealias Appearance = KeepTalkingMappingAppearance

    @Test("an attachment claims its blob on save and the claim goes with the row")
    func attachmentClaims() async throws {
        try await withStore { database, blobStore in
            let (context, node) = try await makeContext(on: database)
            let blobID = try await KeepTalkingClient.storeBlob(
                Data("photo".utf8), mimeType: "image/png", on: database, blobStore: blobStore)
            let message = KeepTalkingContextMessage(
                context: context, sender: .node(node: node), content: "here", timestamp: Date())
            try await message.save(on: database)
            let attachment = KeepTalkingContextAttachment(
                context: context, parentMessageID: try message.requireID(), sender: .node(node: node), blobID: blobID,
                filename: "photo.png", mimeType: "image/png", byteCount: 5, metadata: .init())
            try await attachment.save(on: database)

            #expect(try await claims(for: blobID, on: database) == 1)
            #expect(try await KeepTalkingClient.pruneAllStrayBlobs(on: database, blobStore: blobStore).isEmpty)

            try await message.delete(on: database)
            #expect(try await claims(for: blobID, on: database) == 0)
            #expect(
                try await KeepTalkingClient.pruneStrayBlobs(among: [blobID], on: database, blobStore: blobStore) == [
                    blobID
                ])
            #expect(try await blobRecordIDs(on: database).isEmpty)
        }
    }

    @Test("a blob two owners hold survives losing one of them")
    func sharedBlobSurvives() async throws {
        try await withStore { database, blobStore in
            let (context, node) = try await makeContext(on: database)
            let blobID = try await KeepTalkingClient.storeBlob(
                Data("shared".utf8), mimeType: "image/png", on: database, blobStore: blobStore)
            let attachment = KeepTalkingContextAttachment(
                context: context, sender: .node(node: node), blobID: blobID,
                filename: "shared.png", mimeType: "image/png", byteCount: 6, metadata: .init())
            try await attachment.save(on: database)
            let checkpoint = KeepTalkingWorkspaceStageRow(
                contextID: try context.requireID(),
                stage: .init(schema: "excalidraw-scene", holder: node, blobID: blobID, mimeType: "application/json"))
            try await checkpoint.save(on: database)
            #expect(try await claims(for: blobID, on: database) == 2)

            try await attachment.delete(on: database)
            #expect(try await claims(for: blobID, on: database) == 1)
            #expect(
                try await KeepTalkingClient.pruneStrayBlobs(among: [blobID], on: database, blobStore: blobStore).isEmpty
            )

            let next = try await KeepTalkingClient.storeBlob(
                Data("next".utf8), mimeType: "application/json", on: database, blobStore: blobStore)
            checkpoint.blobID = next
            try await checkpoint.save(on: database)
            #expect(try await claims(for: blobID, on: database) == 0)
            #expect(try await claims(for: next, on: database) == 1)
            #expect(try await KeepTalkingClient.pruneAllStrayBlobs(on: database, blobStore: blobStore) == [blobID])
        }
    }

    @Test("a mapping's claims follow its avatar, and a context delete reports what it held")
    func mappingClaimsFollowAvatar() async throws {
        try await withStore { database, blobStore in
            let (context, node) = try await makeContext(on: database)
            let contextID = try context.requireID()
            let first = try await KeepTalkingClient.storeBlob(
                Data("first".utf8), mimeType: "image/png", on: database, blobStore: blobStore)
            let second = try await KeepTalkingClient.storeBlob(
                Data("second".utf8), mimeType: "image/png", on: database, blobStore: blobStore)
            try await KeepTalkingClient.setAppearance(
                Appearance(avatar: .init(blobID: first)), for: .node(node), scopeContextID: contextID, on: database)
            #expect(try await claims(for: first, on: database) == 1)
            #expect(try await KeepTalkingClient.blobIDsReferenced(byContextID: contextID, on: database) == [first])

            try await KeepTalkingClient.setAppearance(
                Appearance(avatar: .init(blobID: second)), for: .node(node), scopeContextID: contextID, on: database)
            #expect(try await claims(for: first, on: database) == 0)
            #expect(try await claims(for: second, on: database) == 1)

            try await context.delete(on: database)
            #expect(try await claims(for: second, on: database) == 0)
        }
    }

    @Test("the backfill rebuilds claims from the owner rows")
    func backfillRebuildsClaims() async throws {
        try await withStore { database, blobStore in
            let (context, node) = try await makeContext(on: database)
            let blobID = try await KeepTalkingClient.storeBlob(
                Data("old".utf8), mimeType: "image/png", on: database, blobStore: blobStore)
            try await KeepTalkingContextAttachment(
                context: context, sender: .node(node: node), blobID: blobID,
                filename: "old.png", mimeType: "image/png", byteCount: 3, metadata: .init()
            ).save(on: database)
            try await KeepTalkingClient.setAppearance(
                Appearance(avatar: .init(blobID: blobID)), for: .node(node), on: database)
            try await KeepTalkingBlobClaim.query(on: database).delete()
            #expect(try await claims(for: blobID, on: database) == 0)

            try await KeepTalkingBlobClaim.backfill(on: database)
            #expect(try await claims(for: blobID, on: database) == 2)
            try await KeepTalkingBlobClaim.backfill(on: database)
            #expect(try await claims(for: blobID, on: database) == 2)
        }
    }

    // MARK: - Helpers

    private func claims(for blobID: String, on database: any Database) async throws -> Int {
        try await KeepTalkingBlobClaim.query(on: database).filter(\.$blobID == blobID).count()
    }

    private func blobRecordIDs(on database: any Database) async throws -> Set<String> {
        Set(try await KeepTalkingBlobRecord.query(on: database).all(\.$id).compactMap { $0 })
    }

    private func makeContext(on database: any Database) async throws -> (KeepTalkingContext, UUID) {
        let node = KeepTalkingNode(id: UUID())
        try await node.save(on: database)
        let context = KeepTalkingContext(id: UUID())
        try await context.save(on: database)
        return (context, try node.requireID())
    }

    private func withStore(_ body: (any Database, KeepTalkingBlobStore) async throws -> Void) async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobClaimTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }
        do {
            try await body(localStore.database, KeepTalkingBlobStore(baseURL: baseURL))
        } catch {
            await localStore.shutdown()
            throw error
        }
        await localStore.shutdown()
    }
}
