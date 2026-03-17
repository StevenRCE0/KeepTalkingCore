import FluentKit

struct AddContextSyncMetadataMigration: Migration {
    func prepare(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingContext.schema)
            .field("sync_metadata", .json)
            .update()
    }

    func revert(on database: any Database) -> EventLoopFuture<Void> {
        database.schema(KeepTalkingContext.schema)
            .deleteField("sync_metadata")
            .update()
    }
}
