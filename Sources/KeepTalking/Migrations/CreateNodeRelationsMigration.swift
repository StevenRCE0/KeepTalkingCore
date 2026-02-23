import FluentKit

struct CreateKeepTalkingNodeRelationsMigration: Migration {
    func prepare(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingNodeRelation.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("relationship", .string, .required)
            .field("from", .uuid, .required, .references(KeepTalkingNode.schema, "id", onDelete: .cascade))
            .field("to", .uuid, .required, .references(KeepTalkingNode.schema, "id", onDelete: .cascade))
            .field("authorised_actions", .data, .required)
            .create()
    }

    func revert(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingNodeRelation.schema).delete()
    }
}
