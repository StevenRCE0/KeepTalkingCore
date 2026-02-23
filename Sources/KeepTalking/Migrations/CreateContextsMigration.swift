import FluentKit

struct CreateKeepTalkingContextsMigration: Migration {
    func prepare(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingContext.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("updated_at", .datetime, .required)
            .create()
    }

    func revert(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingContext.schema).delete()
    }
}
