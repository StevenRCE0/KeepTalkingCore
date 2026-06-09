import Foundation

/// Holds files that peers have *preflighted* (staged) onto this node ahead of a
/// tool call, keyed by an opaque handle. A real action call then references the
/// handle for its input file object; the executor resolves it to the staged
/// path. Handles are caller-scoped, time-bounded, and quota-bounded — staging is
/// the acceptance point, so abandoned stages expire and no single caller can
/// exhaust the temp disk. (The caller's authorization to stage at all is checked
/// by the preflight handler before anything reaches this store.)
actor KeepTalkingStagedFileStore {
    private struct Entry {
        let url: URL
        let callerNodeID: UUID
        let filename: String
        let byteCount: Int
        var createdAt: Date
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
    func register(handle: UUID, url: URL, callerNodeID: UUID, filename: String, byteCount: Int) {
        entries[handle] = Entry(
            url: url, callerNodeID: callerNodeID, filename: filename,
            byteCount: byteCount, createdAt: Date())
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

    func discard(handle: UUID) {
        guard let entry = entries.removeValue(forKey: handle) else { return }
        totalBytes = max(0, totalBytes - entry.byteCount)
        let remaining = (bytesByCaller[entry.callerNodeID] ?? 0) - entry.byteCount
        bytesByCaller[entry.callerNodeID] = remaining > 0 ? remaining : nil
        try? FileManager.default.removeItem(at: entry.url.deletingLastPathComponent())
    }

    // MARK: - Private

    private func reap() {
        let cutoff = Date().addingTimeInterval(-ttl)
        let stale = entries.compactMap { $0.value.createdAt < cutoff ? $0.key : nil }
        for handle in stale { discard(handle: handle) }
    }

    /// A destination name inside `directory` that doesn't collide with an
    /// existing file (another staged input, or a context attachment already
    /// staged there), preserving the original name where possible.
    private func nonCollidingDestination(for filename: String, in directory: URL) -> URL {
        let safe = (filename as NSString).lastPathComponent
        let base = safe.isEmpty ? "file" : safe
        var candidate = directory.appendingPathComponent(base, isDirectory: false)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(counter)_\(base)", isDirectory: false)
            counter += 1
        }
        return candidate
    }
}
