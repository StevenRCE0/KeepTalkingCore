import FluentKit

struct CreateKeepTalkingMappingsMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingMapping.schema)
            .id()
            .field(
                "node",
                .uuid,
                .references(KeepTalkingNode.schema, "id", onDelete: .cascade)
            )
            .field(
                "context",
                .uuid,
                .references(KeepTalkingContext.schema, "id", onDelete: .cascade)
            )
            .field(
                "thread",
                .uuid,
                .references(KeepTalkingThread.schema, "id", onDelete: .cascade)
            )
            .field("kind", .string, .required)
            .field("namespace", .string)
            .field("value", .string, .required)
            .field("normalized_value", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .field("deleted_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingMapping.schema).delete()
    }
}

struct AddKeepTalkingMappingActionMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingMapping.schema)
            .field(
                "action",
                .uuid,
                .references(KeepTalkingAction.schema, "id", onDelete: .cascade)
            )
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database
            .schema(KeepTalkingMapping.schema)
            .deleteField("action")
            .update()
    }
}

struct AddKeepTalkingMappingScopeContextMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingMapping.schema)
            .field(
                "scope_context",
                .uuid,
                .references(KeepTalkingContext.schema, "id", onDelete: .cascade)
            )
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database
            .schema(KeepTalkingMapping.schema)
            .deleteField("scope_context")
            .update()
    }
}

/// Adds the JSON `appearance` column (colour, icon, avatar). Everything inside
/// it is versioned by its own keys, so later appearance properties land without
/// another migration.
struct AddKeepTalkingMappingAppearanceMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingMapping.schema)
            .field("appearance", .json)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database
            .schema(KeepTalkingMapping.schema)
            .deleteField("appearance")
            .update()
    }
}

/// Adds `suggestion` (JSON): what a target shared about itself. Where the
/// local node's own alias is shared lives in
/// `KeepTalkingContextWiseAliasRelation`, not on the row.
struct AddKeepTalkingMappingSharingMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingMapping.schema)
            .field("suggestion", .json)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingMapping.schema)
            .deleteField("suggestion")
            .update()
    }
}

/// The context ↔ own-alias sharing decisions. One row per context and alias
/// row; either side's deletion takes the row with it.
struct CreateKeepTalkingContextWiseAliasRelationsMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingContextWiseAliasRelation.schema)
            .id()
            .field(
                "context",
                .uuid,
                .required,
                .references(KeepTalkingContext.schema, "id", onDelete: .cascade)
            )
            .field(
                "alias",
                .uuid,
                .required,
                .references(KeepTalkingMapping.schema, "id", onDelete: .cascade)
            )
            .field("is_shared", .bool, .required)
            .unique(on: "context", "alias")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingContextWiseAliasRelation.schema).delete()
    }
}
