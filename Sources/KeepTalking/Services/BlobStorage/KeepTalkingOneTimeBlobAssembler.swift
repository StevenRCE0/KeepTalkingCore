import Foundation

/// Receives and reassembles inbound one-time-blob (OTB) frames. Each transfer
/// gets a private temp directory; each encrypted chunk is written as its own
/// file (named by chunk index, so ordering and boundaries are intrinsic).
/// Nothing here touches the blob store, blob records, or context attachments —
/// the bytes stay ciphertext until `KeepTalkingClient` materializes them with
/// the unsealed key (which also verifies the sender).
actor KeepTalkingOneTimeBlobAssembler {
    private struct Transfer {
        let directory: URL
        var receivedIndices: Set<Int> = []
        var expectedChunkCount: Int?
        var totalBytes: Int = 0
        var lastActivity: Date = Date()
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

        /// Complete only when the received indices are exactly the contiguous
        /// range `0..<expectedChunkCount` — count parity alone would let a
        /// missing chunk hide behind an out-of-range one (silent corruption).
        var isComplete: Bool {
            guard let expectedChunkCount else { return false }
            return receivedIndices == Set(0..<expectedChunkCount)
        }
    }

    private let baseDirectory: URL
    private let maxConcurrentTransfers: Int
    private let maxTransferBytes: Int
    private var transfers: [UUID: Transfer] = [:]
    /// Transfer IDs already discarded — late/duplicate frames for these are
    /// dropped rather than resurrecting a fresh entry + temp dir. Bounded.
    private var discarded: Set<UUID> = []
    private static let maxDiscardedTombstones = 4_096

    init(
        baseDirectory: URL? = nil,
        maxConcurrentTransfers: Int = 64,
        maxTransferBytes: Int = 512 * 1024 * 1024
    ) {
        self.baseDirectory =
            baseDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kt-otb-inbound", isDirectory: true)
        self.maxConcurrentTransfers = maxConcurrentTransfers
        self.maxTransferBytes = maxTransferBytes
    }

    /// Records an inbound ciphertext chunk, creating the per-transfer dir on the
    /// first chunk. Drops out-of-range/over-budget chunks and refuses to revive
    /// a discarded transfer.
    func appendChunk(transferID: UUID, chunkIndex: Int, payload: Data) {
        reapStale()
        guard !discarded.contains(transferID), chunkIndex >= 0 else { return }
        if let expected = transfers[transferID]?.expectedChunkCount, chunkIndex >= expected {
            return
        }
        // Refuse to clobber an already-received chunk: a second frame for the
        // same index (buggy retransmit or a hostile peer) must not overwrite the
        // legitimate ciphertext.
        if transfers[transferID]?.receivedIndices.contains(chunkIndex) == true {
            transfers[transferID]?.lastActivity = Date()
            return
        }
        if transfers[transferID] == nil, transfers.count >= maxConcurrentTransfers { return }

        var transfer = transfers[transferID] ?? makeTransfer(transferID)
        if transfer.totalBytes + payload.count > maxTransferBytes {
            transfers[transferID] = transfer
            discard(
                transferID: transferID,
                error: KeepTalkingOneTimeBlobError.transferTimedOut(transferID))
            return
        }
        let chunkURL = transfer.directory.appendingPathComponent(
            chunkFilename(chunkIndex), isDirectory: false)
        do {
            try payload.write(to: chunkURL, options: .atomic)
            if transfer.receivedIndices.insert(chunkIndex).inserted {
                transfer.totalBytes += payload.count
            }
        } catch {
            // Drop a chunk we can't persist; completion will time out upstream.
        }
        transfer.lastActivity = Date()
        transfers[transferID] = transfer
        resumeIfComplete(transferID)
    }

    /// Records the expected chunk count from the transfer's completion frame.
    func markComplete(transferID: UUID, chunkCount: Int) {
        reapStale()
        guard !discarded.contains(transferID) else { return }
        if transfers[transferID] == nil, transfers.count >= maxConcurrentTransfers { return }
        var transfer = transfers[transferID] ?? makeTransfer(transferID)
        transfer.expectedChunkCount = chunkCount
        transfer.lastActivity = Date()
        transfers[transferID] = transfer
        resumeIfComplete(transferID)
    }

    /// Discards transfers idle beyond the bound so an abandoned/unreferenced OTB
    /// (chunks streamed for a transferID no action call ever materializes) can't
    /// hold a concurrency slot + temp bytes until process restart. Bounded by
    /// `maxConcurrentTransfers`, so iterating on each frame is cheap.
    private func reapStale() {
        let cutoff = Date().addingTimeInterval(-Self.idleTimeout)
        let stale = transfers.compactMap { $0.value.lastActivity < cutoff ? $0.key : nil }
        for id in stale { discard(transferID: id) }
    }

    private static let idleTimeout: TimeInterval = 120

    /// Suspends until the transfer is fully received. Cancellation-aware: if the
    /// awaiting task is cancelled (e.g. the materialize timeout fires), the
    /// waiter is resumed with `CancellationError` so the surrounding task group
    /// can't deadlock on a parked continuation during teardown.
    func awaitCompletion(transferID: UUID) async throws {
        if let transfer = transfers[transferID], transfer.isComplete { return }
        if discarded.contains(transferID) {
            throw KeepTalkingOneTimeBlobError.transferTimedOut(transferID)
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                var transfer = transfers[transferID] ?? makeTransfer(transferID)
                if transfer.isComplete {
                    continuation.resume()
                } else {
                    transfer.waiters[waiterID] = continuation
                    transfers[transferID] = transfer
                }
            }
        } onCancel: {
            Task { await self.failWaiter(transferID: transferID, waiterID: waiterID) }
        }
    }

    /// Returns the ciphertext chunks paired with their indices, in order, so the
    /// caller can bind each chunk's index into its AEAD when decrypting.
    func orderedCiphertextChunks(transferID: UUID) throws -> [(index: Int, data: Data)] {
        guard let transfer = transfers[transferID] else {
            throw KeepTalkingOneTimeBlobError.transferTimedOut(transferID)
        }
        var chunks: [(index: Int, data: Data)] = []
        chunks.reserveCapacity(transfer.receivedIndices.count)
        for index in transfer.receivedIndices.sorted() {
            let url = transfer.directory.appendingPathComponent(
                chunkFilename(index), isDirectory: false)
            chunks.append((index, try Data(contentsOf: url)))
        }
        return chunks
    }

    /// Removes a transfer's temp directory, tombstones it, and fails any pending
    /// waiters.
    func discard(transferID: UUID, error: Error? = nil) {
        rememberDiscarded(transferID)
        guard let transfer = transfers.removeValue(forKey: transferID) else { return }
        try? FileManager.default.removeItem(at: transfer.directory)
        let failure = error ?? KeepTalkingOneTimeBlobError.transferTimedOut(transferID)
        for (_, continuation) in transfer.waiters { continuation.resume(throwing: failure) }
    }

    // MARK: - Private

    private func failWaiter(transferID: UUID, waiterID: UUID) {
        guard var transfer = transfers[transferID],
            let continuation = transfer.waiters.removeValue(forKey: waiterID)
        else { return }
        transfers[transferID] = transfer
        continuation.resume(throwing: CancellationError())
    }

    private func rememberDiscarded(_ transferID: UUID) {
        if discarded.count >= Self.maxDiscardedTombstones { discarded.removeAll() }
        discarded.insert(transferID)
    }

    private func makeTransfer(_ transferID: UUID) -> Transfer {
        let dir = baseDirectory.appendingPathComponent(
            transferID.uuidString.lowercased(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Transfer(directory: dir)
    }

    private func resumeIfComplete(_ transferID: UUID) {
        guard var transfer = transfers[transferID], transfer.isComplete,
            !transfer.waiters.isEmpty
        else { return }
        let waiters = transfer.waiters
        transfer.waiters = [:]
        transfers[transferID] = transfer
        for (_, continuation) in waiters { continuation.resume() }
    }

    private func chunkFilename(_ index: Int) -> String {
        String(format: "%08d.cbin", index)
    }
}
