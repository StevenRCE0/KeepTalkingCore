import FluentKit

struct CreateKeepTalkingNodeRelationsMigration: Migration {
    func prepare(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingNodeRelation.schema)
            .id()
            .field("relationship", .json, .required)
            .field("from", .uuid, .required, .references(KeepTalkingNode.schema, "id", onDelete: .cascade))
            .field("to", .uuid, .required, .references(KeepTalkingNode.schema, "id", onDelete: .cascade))
            .create()
    }

    func revert(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingNodeRelation.schema).delete()
    }
}
