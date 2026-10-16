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
            .field("color_hex", .string)
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

/// Adds the alias-sharing columns: `suggestion` (what a target shared about
/// itself) and `shared_in_contexts` (where the local node's own alias is
/// shared). Both JSON.
struct AddKeepTalkingMappingSharingMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingMapping.schema)
            .field("suggestion", .json)
            .update()
        try await database.schema(KeepTalkingMapping.schema)
            .field("shared_in_contexts", .json)
            .update()
    }

    /// One `.update()` per column: SQLite takes a single `DROP COLUMN` per
    /// `ALTER TABLE`.
    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingMapping.schema)
            .deleteField("shared_in_contexts")
            .update()
        try await database.schema(KeepTalkingMapping.schema)
            .deleteField("suggestion")
            .update()
    }
}
