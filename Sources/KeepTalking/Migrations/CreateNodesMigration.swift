import FluentKit

struct CreateKeepTalkingNodesMigration: Migration {
    func prepare(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingNode.schema)
            .id()
            .field("last_seen_at", .datetime, .required)
            .field("context_wake_handles", .json)
            .create()
    }

    func revert(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingNode.schema).delete()
    }
}
