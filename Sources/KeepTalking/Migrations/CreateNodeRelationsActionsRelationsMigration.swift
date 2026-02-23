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
                .references(KeepTalkingAction.schema, "id")
            )
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database
            .schema(KeepTalkingNodeRelationActionRelation.schema)
            .delete()
    }
}
