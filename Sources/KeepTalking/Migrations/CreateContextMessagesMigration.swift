import FluentKit

struct CreateKeepTalkingContextMessagesMigration: Migration {
    func prepare(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingContextMessage.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("context", .uuid, .required, .references(KeepTalkingContext.schema, "id", onDelete: .cascade))
            .field("sender", .data, .required)
            .field("content", .string, .required)
            .field("timestamp", .datetime, .required)
            .create()
    }

    func revert(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingContextMessage.schema).delete()
    }
}
