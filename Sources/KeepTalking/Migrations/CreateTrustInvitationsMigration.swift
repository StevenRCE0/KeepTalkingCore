import FluentKit

struct CreateKeepTalkingTrustInvitationsMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingTrustInvitation.schema)
            .id()
            .field(
                "context",
                .uuid,
                .required,
                .references(KeepTalkingContext.schema, "id", onDelete: .cascade)
            )
            .field("inviter_node_id", .uuid, .required)
            .field("recipient_node_id", .uuid, .required)
            .field("direction", .json, .required)
            .field("status", .json, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .field("resolved_at", .datetime)
            .field("last_error", .string)
            .unique(
                on: "context",
                "inviter_node_id",
                "recipient_node_id",
                "direction"
            )
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingTrustInvitation.schema).delete()
    }
}
