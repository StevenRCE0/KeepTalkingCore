import FluentKit

struct CreateKeepTalkingContextsMigration: Migration {
    func prepare(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingContext.schema)
            .id()
            .field("updated_at", .datetime, .required)
            .create()
    }

    func revert(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingContext.schema).delete()
    }
}
