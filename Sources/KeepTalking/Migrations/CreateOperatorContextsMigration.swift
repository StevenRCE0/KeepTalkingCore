import FluentKit

struct CreateKeepTalkingOperatorContextsMigration: Migration {
    func prepare(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingOperatorContext.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("operator", .uuid, .required, .references(KeepTalkingNode.schema, "id", onDelete: .cascade))
            .field("context", .uuid, .required, .references(KeepTalkingContext.schema, "id", onDelete: .cascade))
            .create()
    }

    func revert(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingOperatorContext.schema).delete()
    }
}
