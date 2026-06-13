import FluentKit
import Foundation

extension KeepTalkingClient {

    /// Get-or-create the execution workspace dir for a thread, recording a
    /// tracking row (idempotent; unique on thread). Returns the canonical dir URL
    /// used as `cwd` for the thread's skill / provider-side ACT runs.
    func threadWorkspace(for threadID: UUID) async throws -> URL {
        let dir = try await threadWorkspaces.workspace(for: threadID)
        let existing = try? await KeepTalkingThreadWorkspace.query(on: localStore.database)
            .filter(\.$thread.$id == threadID)
            .first()
        if existing == nil {
            let row = KeepTalkingThreadWorkspace(threadID: threadID, path: dir.path)
            try? await row.save(on: localStore.database)
        }
        return dir
    }

    /// Brackets a run in a thread's workspace so a concurrent seal DEFERS until it
    /// drains (the seal-vs-in-flight race). Always pair `begin` with `end`.
    func beginThreadWorkspaceRun(_ threadID: UUID) async {
        await threadWorkspaces.beginRun(threadID: threadID)
    }

    func endThreadWorkspaceRun(_ threadID: UUID) async {
        await threadWorkspaces.endRun(threadID: threadID)
    }

    /// Seal (delete) a thread's workspace dir + tracking row. Called on thread
    /// archive/delete; the dir delete defers while a run is in flight.
    func sealThreadWorkspace(_ threadID: UUID) async {
        await threadWorkspaces.seal(threadID: threadID)
        if let row = try? await KeepTalkingThreadWorkspace.query(on: localStore.database)
            .filter(\.$thread.$id == threadID)
            .first()
        {
            try? await row.delete(on: localStore.database)
        }
    }

    /// Reap workspaces whose thread is archived or no longer exists. Hooked into
    /// startup + the periodic housekeeping reconciler. Two layers: (1) DB-driven —
    /// seal any tracked workspace whose thread is archived/dangling; (2) FS-level —
    /// sweep dirs whose row was cascade-deleted with the thread.
    func reapOrphanThreadWorkspaces() async {
        let rows =
            (try? await KeepTalkingThreadWorkspace.query(on: localStore.database)
                .with(\.$thread)
                .all()) ?? []
        var liveThreadIDs = Set<UUID>()
        for row in rows {
            if let thread = row.$thread.value, thread.state != .archived {
                liveThreadIDs.insert(row.$thread.id)
            } else {
                await threadWorkspaces.seal(threadID: row.$thread.id)
                try? await row.delete(on: localStore.database)
            }
        }
        await threadWorkspaces.reapOrphans(
            liveThreadIDs: liveThreadIDs,
            maxAge: 7 * 24 * 60 * 60)
    }
}
