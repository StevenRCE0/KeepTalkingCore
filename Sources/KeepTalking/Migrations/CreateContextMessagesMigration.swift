import FluentKit

struct CreateKeepTalkingContextMessagesMigration: Migration {
    func prepare(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingContextMessage.schema)
            .id()
            .field("context", .uuid, .required, .references(KeepTalkingContext.schema, "id", onDelete: .cascade))
            .field("sender", .json, .required)
            .field("content", .string, .required)
            .field("timestamp", .datetime, .required)
            .create()
    }

    func revert(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingContextMessage.schema).delete()
    }
}
