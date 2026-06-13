import Foundation

/// Owns per-thread, isolated, sealable EXECUTION WORKSPACES — the read-write
/// scratch + output directory a skill / provider-side ACT run uses as its `cwd`.
///
/// Design (see project_keeptalking_execution_architecture):
/// - SEPARATE from the read-only skill resource folder, so a script writing a
///   relative file can no longer pollute the installed skill (the `cwd`
///   pollution fix), AND separate from per-call attachment/OTB staging, which
///   stays the fail-closed, per-call-cleaned INPUT surface. The workspace is the
///   OUTPUT / scratch surface.
/// - THREAD-scoped: persists across a thread's turns/runs (the long-running task
///   workspace that bridges turns), reaped at thread seal or as an orphan — NOT
///   per-call.
/// - PERSISTENT base under `databaseURL/../workspaces` (a thread is a durable
///   semantic unit; survives restart), bounded by orphan-reaping + a soft
///   per-thread byte quota (seatbelt can't enforce a hard quota).
/// - Paths are symlink-resolved + standardized so they match the granted
///   seatbelt subpath (the /var vs /private/var trap).
/// - macOS-only: there is no `Process`/Seatbelt on iOS; iOS delegates execution.
public actor KeepTalkingThreadWorkspaceManager {

    /// Persistent root holding one subdirectory per thread.
    private let baseDirectory: URL

    /// Soft per-thread byte ceiling, checked best-effort before a run.
    private let perThreadByteQuota: Int

    /// Per-thread in-flight run count. `seal` DEFERS while this is > 0 so a
    /// workspace is never deleted out from under a running script that holds it
    /// as `cwd` (the seal-vs-in-flight race).
    private var activeRuns: [UUID: Int] = [:]

    /// Threads whose seal was requested while a run was still in flight; the
    /// delete fires when the last run drains.
    private var sealPending: Set<UUID> = []

    public init(baseDirectory: URL, perThreadByteQuota: Int = 512 * 1024 * 1024) {
        self.baseDirectory = baseDirectory
        self.perThreadByteQuota = perThreadByteQuota
    }

    /// Manager rooted next to the SQLite database (mirrors `KeepTalkingBlobStore`).
    public static func makeDefault(
        databaseURL: URL,
        perThreadByteQuota: Int = 512 * 1024 * 1024
    ) -> KeepTalkingThreadWorkspaceManager {
        let base = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("workspaces", isDirectory: true)
        return KeepTalkingThreadWorkspaceManager(
            baseDirectory: base, perThreadByteQuota: perThreadByteQuota)
    }

    /// Manager derived from a local store (mirrors `KeepTalkingBlobStore`): rooted
    /// next to the SQLite DB for a model store, else a temp dir (in-memory/tests).
    public static func makeDefault(
        for localStore: any KeepTalkingLocalStore,
        perThreadByteQuota: Int = 512 * 1024 * 1024
    ) -> KeepTalkingThreadWorkspaceManager {
        let base: URL
        if let modelStore = localStore as? KeepTalkingModelStore {
            base = modelStore.databaseURL.deletingLastPathComponent()
                .appendingPathComponent("workspaces", isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("KeepTalking-Workspaces", isDirectory: true)
        }
        return KeepTalkingThreadWorkspaceManager(
            baseDirectory: base, perThreadByteQuota: perThreadByteQuota)
    }

    // MARK: - Lifecycle

    /// Idempotent get-or-create. Returns the canonical (symlink-resolved,
    /// standardized) workspace URL for `threadID`, so the path equals the granted
    /// seatbelt subpath at access time.
    public func workspace(for threadID: UUID) throws -> URL {
        let dir = directory(for: threadID)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Mark a run active so `seal` defers until it drains. Pair with `endRun`
    /// (the executor brackets each run: begin → run → end).
    public func beginRun(threadID: UUID) {
        activeRuns[threadID, default: 0] += 1
    }

    /// Balance a `beginRun`; performs a deferred seal when the last run drains.
    public func endRun(threadID: UUID) {
        guard let count = activeRuns[threadID] else { return }
        if count <= 1 {
            activeRuns[threadID] = nil
            if sealPending.remove(threadID) != nil { performSeal(threadID) }
        } else {
            activeRuns[threadID] = count - 1
        }
    }

    /// Idempotent delete of a thread's workspace. DEFERS while a run is in flight
    /// (completes on the last `endRun`). Called on turning-point/archive/delete
    /// per the seal-trigger policy.
    public func seal(threadID: UUID) {
        if activeRuns[threadID] != nil {
            sealPending.insert(threadID)
            return
        }
        performSeal(threadID)
    }

    /// Selective sweep: delete workspaces whose thread is NOT in `liveThreadIDs`
    /// and older than `maxAge` and has no active run. NOT a blanket prefix-delete
    /// — only true orphans (a thread row that no longer exists). Wired into
    /// startup + the periodic housekeeping reconciler.
    public func reapOrphans(liveThreadIDs: Set<UUID>, maxAge: TimeInterval) {
        let fileManager = FileManager.default
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: baseDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return }
        let now = Date()
        for entry in entries {
            guard let threadID = UUID(uuidString: entry.lastPathComponent) else { continue }
            if liveThreadIDs.contains(threadID) { continue }
            if activeRuns[threadID] != nil { continue }
            let modified =
                (try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) < maxAge { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    // MARK: - Quota (best-effort; seatbelt cannot enforce a hard cap)

    /// Best-effort pre-run check that a thread's workspace is under the soft byte
    /// quota. A runaway script can still exceed it within one run — this only
    /// gates STARTING a run, it does not bound a single run's writes.
    public func isUnderQuota(threadID: UUID) -> Bool {
        // TODO(Phase 1): sum file sizes under directory(for: threadID); compare to
        // perThreadByteQuota. Stubbed permissive until wired.
        return true
    }

    // MARK: - Private

    private func directory(for threadID: UUID) -> URL {
        baseDirectory.appendingPathComponent(
            threadID.uuidString.lowercased(), isDirectory: true)
    }

    private func performSeal(_ threadID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: threadID))
    }
}
