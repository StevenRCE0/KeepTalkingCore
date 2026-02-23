import FluentKit

struct CreateKeepTalkingNodesMigration: Migration {
    func prepare(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingNode.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("last_seen_at", .datetime, .required)
            .create()
    }

    func revert(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingNode.schema).delete()
    }
}
