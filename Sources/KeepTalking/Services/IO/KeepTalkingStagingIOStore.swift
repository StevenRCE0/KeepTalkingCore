import Foundation

/// Holds files that peers have *preflighted* (staged) onto this node ahead of a
/// tool call, keyed by an opaque handle. A real action call then references the
/// handle for its input file object; the executor resolves it to the staged
/// path. Handles are caller-scoped, time-bounded, and quota-bounded — staging is
/// the acceptance point, so abandoned stages expire and no single caller can
/// exhaust the temp disk. (The caller's authorization to stage at all is checked
/// by the preflight handler before anything reaches this store.)
actor KeepTalkingStagingIOStore {
    private struct Entry {
        let url: URL
        let callerNodeID: UUID
        let filename: String
        let byteCount: Int
        var createdAt: Date
        /// Whether this entry is destroyed the first time an action call consumes
        /// it (`discardIfConsumable`). TRUE for ephemeral INPUT relays (a peer
        /// preflight or a `kt_send_file` stage made just ahead of one call). FALSE
        /// for PRODUCED outputs (an action's `.otb` result staged for re-feeding /
        /// A→B chaining) — those must survive consumption so the same handle can
        /// flow into a later action; TTL + quota reclaim them instead.
        let consumeOnUse: Bool
    }

    private let baseDirectory: URL
    private let ttl: TimeInterval
    private let maxEntries: Int
    private let maxTotalBytes: Int
    private let maxBytesPerCaller: Int
    private var entries: [UUID: Entry] = [:]
    private var totalBytes = 0
    private var bytesByCaller: [UUID: Int] = [:]

    init(
        baseDirectory: URL? = nil,
        ttl: TimeInterval = 600,
        maxEntries: Int = 128,
        maxTotalBytes: Int = 1 * 1024 * 1024 * 1024,
        maxBytesPerCaller: Int = 256 * 1024 * 1024
    ) {
        self.baseDirectory =
            baseDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kt-staged-files", isDirectory: true)
        self.ttl = ttl
        self.maxEntries = maxEntries
        self.maxTotalBytes = maxTotalBytes
        self.maxBytesPerCaller = maxBytesPerCaller
    }

    /// Reserves a staging dir for a preflight IFF it fits within the count and
    /// byte quotas (aggregate + per-caller), so an over-quota stage is rejected
    /// BEFORE decrypting — and a hostile caller can't evict another caller's
    /// staged file. `nil` means refuse. `expectedBytes` is the declared transfer
    /// size; the real size is reconciled at `register`.
    func makeStagingDirectory(
        expectedBytes: Int, callerNodeID: UUID
    ) -> (handle: UUID, directory: URL)? {
        reap()
        guard entries.count < maxEntries,
            totalBytes + expectedBytes <= maxTotalBytes,
            (bytesByCaller[callerNodeID] ?? 0) + expectedBytes <= maxBytesPerCaller
        else { return nil }
        let handle = UUID()
        let dir = baseDirectory.appendingPathComponent(
            handle.uuidString.lowercased(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (handle, dir)
    }

    /// Registers an already-materialized staged file and accounts its bytes.
    /// `consumeOnUse` defaults true (an ephemeral input relay destroyed on first
    /// consume); pass false for a PRODUCED output that must be re-feedable.
    func register(
        handle: UUID, url: URL, callerNodeID: UUID, filename: String,
        byteCount: Int, consumeOnUse: Bool = true
    ) {
        entries[handle] = Entry(
            url: url, callerNodeID: callerNodeID, filename: filename,
            byteCount: byteCount, createdAt: Date(), consumeOnUse: consumeOnUse)
        totalBytes += byteCount
        bytesByCaller[callerNodeID, default: 0] += byteCount
    }

    /// Resolves a caller-owned handle and copies its file into `directory`,
    /// disambiguating against existing names — ALL under actor isolation, so no
    /// reap/eviction can delete the staged file between lookup and copy (no
    /// TOCTOU). Returns nil if the handle is unknown, foreign, or its bytes have
    /// vanished. Throws only on a genuine copy failure.
    func copyStagedFile(
        handle: UUID, callerNodeID: UUID, into directory: URL
    ) throws -> URL? {
        reap()
        guard let entry = entries[handle], entry.callerNodeID == callerNodeID,
            FileManager.default.fileExists(atPath: entry.url.path)
        else { return nil }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let dest = nonCollidingDestination(for: entry.filename, in: directory)
        try FileManager.default.copyItem(at: entry.url, to: dest)
        return dest
    }

    /// Stages a LOCAL file into the private store (e.g. a primitive's private
    /// `.otb` output) and returns its handle. Unlike peer preflight, the bytes are
    /// already local — this reserves a quota-checked dir, copies the file in, and
    /// registers it. The result is NEVER an attachment and NEVER synced/broadcast;
    /// callers inject it into the next model turn and keep the handle for chaining.
    /// Registered as RE-FEEDABLE (not consume-on-use): a produced `.otb` output is
    /// meant to flow into a later action call (A→B chaining), so consuming it once
    /// must not destroy it — TTL + quota reclaim it instead.
    func stageLocalFile(
        at sourceURL: URL, filename: String, callerNodeID: UUID,
        consumeOnUse: Bool = false
    ) -> (handle: UUID, byteCount: Int)? {
        let byteCount =
            ((try? FileManager.default.attributesOfItem(atPath: sourceURL.path))?[.size]
                as? Int) ?? 0
        guard
            let (handle, dir) = makeStagingDirectory(
                expectedBytes: byteCount, callerNodeID: callerNodeID)
        else { return nil }
        let name = safeFileName(filename)
        let dest = dir.appendingPathComponent(name, isDirectory: false)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            discard(handle: handle)
            return nil
        }
        register(
            handle: handle, url: dest, callerNodeID: callerNodeID,
            filename: name, byteCount: byteCount, consumeOnUse: consumeOnUse)
        return (handle, byteCount)
    }

    /// Resolves a caller-owned staged handle to its file + metadata. Caller-scoped:
    /// a foreign or unknown handle (or one whose bytes vanished) returns nil.
    func file(
        handle: UUID, callerNodeID: UUID
    ) -> (url: URL, filename: String, byteCount: Int)? {
        reap()
        guard let entry = entries[handle], entry.callerNodeID == callerNodeID,
            FileManager.default.fileExists(atPath: entry.url.path)
        else { return nil }
        return (entry.url, entry.filename, entry.byteCount)
    }

    /// Diagnostic (logs only): why `handle` won't resolve for `callerNodeID`.
    /// `reap()` has already removed TTL-expired entries by the time a resolve
    /// fails, so "absent" folds expired/discarded/never-staged together.
    func resolutionDiagnosis(handle: UUID, callerNodeID: UUID) -> String {
        guard let entry = entries[handle] else {
            return "absent(never-staged-on-this-node, or expired/discarded)"
        }
        if entry.callerNodeID != callerNodeID {
            return "foreign(owned-by=\(entry.callerNodeID.uuidString.prefix(8)))"
        }
        if !FileManager.default.fileExists(atPath: entry.url.path) {
            return "bytes-vanished"
        }
        return "present(unexpected)"
    }

    func discard(handle: UUID) {
        guard let entry = entries.removeValue(forKey: handle) else { return }
        totalBytes = max(0, totalBytes - entry.byteCount)
        let remaining = (bytesByCaller[entry.callerNodeID] ?? 0) - entry.byteCount
        bytesByCaller[entry.callerNodeID] = remaining > 0 ? remaining : nil
        try? FileManager.default.removeItem(at: entry.url.deletingLastPathComponent())
    }

    /// Post-consumption cleanup for an action call's input handles: discards ONLY
    /// consume-on-use entries (ephemeral relays). A re-feedable PRODUCED output is
    /// left intact so the same handle can flow into a later action call — exactly
    /// the A→B chaining that an unconditional `discard` silently broke.
    func discardIfConsumable(handle: UUID) {
        guard let entry = entries[handle], entry.consumeOnUse else { return }
        discard(handle: handle)
    }

    // MARK: - Private

    private func reap() {
        let cutoff = Date().addingTimeInterval(-ttl)
        let stale = entries.compactMap { $0.value.createdAt < cutoff ? $0.key : nil }
        for handle in stale { discard(handle: handle) }
    }

    private func safeFileName(_ filename: String) -> String {
        let safe = (filename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty || safe == "." || safe == ".." ? "file" : safe
    }

    private func nonCollidingDestination(for filename: String, in directory: URL) -> URL {
        let base = safeFileName(filename)
        var candidate = directory.appendingPathComponent(base, isDirectory: false)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(counter)_\(base)", isDirectory: false)
            counter += 1
        }
        return candidate
    }

}
