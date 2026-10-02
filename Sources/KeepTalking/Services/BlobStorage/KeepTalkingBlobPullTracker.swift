import Foundation

/// Attachment blobs a client is pulling: one holder at a time per blob, and
/// a quiet period between `wanted` announcements of the same blob.
///
/// A pull that never produced a stream lapses after `pullTimeout`, so the
/// next offer (from the same holder or another) can claim the blob again.
actor KeepTalkingBlobPullTracker {
    private struct Pull {
        let holder: UUID
        let startedAt: Date
    }

    static let pullTimeout: TimeInterval = 30
    static let wantedInterval: TimeInterval = 10

    private var pulls: [String: Pull] = [:]
    private var lastWanted: [String: Date] = [:]

    /// The blobs worth announcing as wanted now: not being pulled, and not
    /// announced within `wantedInterval`. Marks them announced.
    func dueForAnnouncement(_ blobIDs: [String], now: Date = Date()) -> [String] {
        var due: [String] = []
        for blobID in Set(blobIDs).sorted() {
            if let pull = pulls[blobID], now.timeIntervalSince(pull.startedAt) < Self.pullTimeout { continue }
            if let last = lastWanted[blobID], now.timeIntervalSince(last) < Self.wantedInterval { continue }
            lastWanted[blobID] = now
            due.append(blobID)
        }
        return due
    }

    /// Claims `blobID` for a pull from `holder`. False while another pull of
    /// it is live.
    func claim(_ blobID: String, from holder: UUID, now: Date = Date()) -> Bool {
        if let pull = pulls[blobID], now.timeIntervalSince(pull.startedAt) < Self.pullTimeout { return false }
        pulls[blobID] = Pull(holder: holder, startedAt: now)
        return true
    }

    /// Whether a stream of `blobID` from `holder` is one we asked for.
    func isPulling(_ blobID: String, from holder: UUID) -> Bool {
        pulls[blobID]?.holder == holder
    }

    /// The pull ended, done or not. The next `wanted` may go out at once.
    func finish(_ blobID: String) {
        pulls[blobID] = nil
        lastWanted[blobID] = nil
    }
}
