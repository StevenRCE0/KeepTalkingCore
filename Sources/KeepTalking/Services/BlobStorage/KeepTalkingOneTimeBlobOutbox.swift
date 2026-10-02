import Crypto
import Foundation

/// One-time blobs this node holds until their recipients pull them.
///
/// Holding takes a snapshot of the file (a clone where the file system has
/// them), so the bytes a recipient pulls are the ones the reference
/// described, even when the source was a temporary file its producer has
/// since deleted. An entry lives `lifetime` from its last pull, then the
/// snapshot goes.
actor KeepTalkingOneTimeBlobOutbox {
    struct Entry: Sendable {
        let fileURL: URL
        let key: SymmetricKey
        let recipient: UUID
        let mimeType: String
        let byteCount: Int
        var expiresAt: Date
    }

    static let lifetime: TimeInterval = 10 * 60

    private let directory: URL
    private var entries: [UUID: Entry] = [:]

    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kt-otb-outbox", isDirectory: true)
    }

    /// Snapshots `fileURL` for `recipient` under a fresh transfer id.
    func hold(
        fileURL: URL,
        key: SymmetricKey,
        recipient: UUID,
        mimeType: String,
        now: Date = Date()
    ) throws -> (transferID: UUID, byteCount: Int) {
        sweep(now: now)
        let transferID = UUID()
        let snapshot = directory.appendingPathComponent(transferID.uuidString.lowercased(), isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fileURL, to: snapshot)
        } catch {
            throw KeepTalkingOneTimeBlobError.sourceUnreadable(fileURL.path)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: snapshot.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        entries[transferID] = Entry(
            fileURL: snapshot,
            key: key,
            recipient: recipient,
            mimeType: mimeType,
            byteCount: byteCount,
            expiresAt: now.addingTimeInterval(Self.lifetime)
        )
        return (transferID, byteCount)
    }

    /// The entry, if `requester` is its recipient. Each pull extends its
    /// life, so a retry after a broken stream still finds it.
    func entry(for transferID: UUID, requester: UUID, now: Date = Date()) -> Entry? {
        sweep(now: now)
        guard var entry = entries[transferID], entry.recipient == requester else { return nil }
        entry.expiresAt = now.addingTimeInterval(Self.lifetime)
        entries[transferID] = entry
        return entry
    }

    /// Drops expired entries and their snapshots.
    func sweep(now: Date = Date()) {
        for (transferID, entry) in entries where entry.expiresAt <= now {
            entries[transferID] = nil
            try? FileManager.default.removeItem(at: entry.fileURL)
        }
    }
}
