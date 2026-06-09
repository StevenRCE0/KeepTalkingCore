//
//  CreateNodeRelationsActionsRelationsMigration.swift
//  KeepTalking
//
//  Created by 砚渤 on 23/02/2026.
//

import FluentKit

struct CreateNodeRelationsActionsRelationsMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingNodeRelationActionRelation.schema)
            .id()
            .field(
                "relation",
                .uuid,
                .required,
                .references(
                    KeepTalkingNodeRelation.schema,
                    "id",
                    onDelete: .cascade
                )
            )
            .field(
                "action",
                .uuid,
                .required,
                .references(
                    KeepTalkingAction.schema,
                    "id",
                    onDelete: .cascade
                )
            )
            .field(
                "approving_context",
                .json,
            )
            .field("wake_handles", .json)
            .field("permission", .json)
            // Reserved for WS3 cross-device authorization (B→C opt-in). Added now
            // so the feature lands without another DB recreation; nullable.
            .field("allow_remote_confirmation", .bool)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database
            .schema(KeepTalkingNodeRelationActionRelation.schema)
            .delete()
    }
}
