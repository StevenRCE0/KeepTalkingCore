import FluentKit
import Foundation

/// Claims are written by the owners' model middleware, never by hand.
public final class KeepTalkingBlobClaim: Model, @unchecked Sendable {
    public static let schema = "kt_blob_claims"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "blob_id")
    public var blobID: String

    @OptionalParent(key: "context")
    public var context: KeepTalkingContext?

    @OptionalParent(key: "attachment")
    public var attachment: KeepTalkingContextAttachment?

    @OptionalParent(key: "mapping")
    public var mapping: KeepTalkingMapping?

    @OptionalParent(key: "workspace_stage")
    public var workspaceStage: KeepTalkingWorkspaceStageRow?

    @OptionalParent(key: "workspace_resource")
    public var workspaceResource: KeepTalkingWorkspaceResourceRow?

    public init() {}

    init(blobID: String, owner: KeepTalkingBlobClaimOwner, contextID: UUID?) {
        self.id = UUID.v7()
        self.blobID = blobID
        self.$context.id = contextID
        switch owner {
            case .attachment(let id): self.$attachment.id = id
            case .mapping(let id): self.$mapping.id = id
            case .workspaceStage(let id): self.$workspaceStage.id = id
            case .workspaceResource(let id): self.$workspaceResource.id = id
        }
    }

    static func reconcile(
        _ owner: KeepTalkingBlobClaimOwner,
        blobIDs: Set<String>,
        contextID: UUID?,
        on database: any Database
    ) async throws {
        let existing = try await query(on: database).filter(owner).all()
        for claim in existing where !blobIDs.contains(claim.blobID) {
            try await claim.delete(on: database)
        }
        let held = Set(existing.map(\.blobID))
        for blobID in blobIDs.subtracting(held).sorted() {
            try await KeepTalkingBlobClaim(blobID: blobID, owner: owner, contextID: contextID).create(on: database)
        }
    }

    static func claimed(among blobIDs: Set<String>, on database: any Database) async throws -> Set<String> {
        var claimed = Set<String>()
        let ids = blobIDs.sorted()
        var start = 0
        while start < ids.count {
            let slice = Array(ids[start..<min(start + 500, ids.count)])
            claimed.formUnion(try await query(on: database).filter(\.$blobID ~~ slice).all(\.$blobID))
            start += slice.count
        }
        return claimed
    }

    static func backfill(on database: any Database) async throws {
        for attachment in try await KeepTalkingContextAttachment.query(on: database).all() {
            try await reconcile(
                .attachment(try attachment.requireID()), blobIDs: [attachment.blobID],
                contextID: attachment.$context.id, on: database)
        }
        for mapping in try await KeepTalkingMapping.query(on: database).all() {
            try await reconcile(
                .mapping(try mapping.requireID()), blobIDs: mapping.blobIDs,
                contextID: mapping.claimContextID, on: database)
        }
        for stage in try await KeepTalkingWorkspaceStageRow.query(on: database).all() {
            try await reconcile(
                .workspaceStage(try stage.requireID()), blobIDs: stage.claimedBlobIDs,
                contextID: stage.$context.id, on: database)
        }
        for resource in try await KeepTalkingWorkspaceResourceRow.query(on: database).all() {
            try await reconcile(
                .workspaceResource(try resource.requireID()), blobIDs: resource.claimedBlobIDs,
                contextID: resource.$context.id, on: database)
        }
    }
}

enum KeepTalkingBlobClaimOwner {
    case attachment(UUID)
    case mapping(UUID)
    case workspaceStage(UUID)
    case workspaceResource(UUID)
}

extension QueryBuilder<KeepTalkingBlobClaim> {
    func filter(_ owner: KeepTalkingBlobClaimOwner) -> Self {
        switch owner {
            case .attachment(let id): return filter(\.$attachment.$id == id)
            case .mapping(let id): return filter(\.$mapping.$id == id)
            case .workspaceStage(let id): return filter(\.$workspaceStage.$id == id)
            case .workspaceResource(let id): return filter(\.$workspaceResource.$id == id)
        }
    }
}

extension KeepTalkingMapping {
    var claimContextID: UUID? { $scopeContext.id ?? $context.id }
}

struct CreateKeepTalkingBlobClaimsMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingBlobClaim.schema)
            .id()
            .field("blob_id", .string, .required)
            .field("context", .uuid, .references(KeepTalkingContext.schema, "id", onDelete: .cascade))
            .field(
                "attachment", .uuid, .references(KeepTalkingContextAttachment.schema, "id", onDelete: .cascade)
            )
            .field("mapping", .uuid, .references(KeepTalkingMapping.schema, "id", onDelete: .cascade))
            .field(
                "workspace_resource", .uuid,
                .references(KeepTalkingWorkspaceResourceRow.schema, "id", onDelete: .cascade)
            )
            .field(
                "workspace_stage", .uuid,
                .references(KeepTalkingWorkspaceStageRow.schema, "id", onDelete: .cascade)
            )
            .unique(on: "blob_id", "attachment")
            .unique(on: "blob_id", "mapping")
            .unique(on: "blob_id", "workspace_resource")
            .unique(on: "blob_id", "workspace_stage")
            .create()
        try await KeepTalkingBlobClaim.backfill(on: database)
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingBlobClaim.schema).delete()
    }
}
