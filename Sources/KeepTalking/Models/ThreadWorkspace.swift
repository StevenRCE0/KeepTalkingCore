import FluentKit
import Foundation

/// DB record tracking a thread's execution WORKSPACE — the isolated read-write
/// scratch/output directory a skill / provider-side ACT run uses as its `cwd`.
///
/// One per thread (the long-running task workspace that bridges turns). The
/// on-disk directory lifecycle is owned by `KeepTalkingThreadWorkspaceManager`;
/// this row makes workspaces queryable and lets the reaper find dirs whose thread
/// has been archived or deleted. The FK cascades on thread delete (so the row
/// disappears with the thread); the manager still removes the dir on the disk.
public final class KeepTalkingThreadWorkspace: Model, @unchecked Sendable {
    public static let schema = "kt_thread_workspaces"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "thread")
    public var thread: KeepTalkingThread

    /// Absolute, symlink-resolved on-disk path of the workspace directory.
    @Field(key: "path")
    public var path: String

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    public init() {}

    public init(id: UUID = UUID.v7(), threadID: UUID, path: String) {
        self.id = id
        self.$thread.id = threadID
        self.path = path
    }
}
