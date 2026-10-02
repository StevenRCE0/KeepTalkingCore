import Crypto
import Foundation
import Testing

@testable import KeepTalkingSDK

/// The bookkeeping behind pull-only blobs: one holder per pull, spaced
/// announcements, and the one-time-blob outbox and assembler.
struct BlobPullTests {
    @Test("A blob is claimed by one holder at a time until the pull ends or lapses")
    func pullClaims() async {
        let tracker = KeepTalkingBlobPullTracker()
        let start = Date()
        let alice = UUID()
        let bob = UUID()
        #expect(await tracker.claim("b", from: alice, now: start))
        #expect(await !tracker.claim("b", from: bob, now: start.addingTimeInterval(1)))
        #expect(await tracker.isPulling("b", from: alice))
        #expect(await !tracker.isPulling("b", from: bob))
        // A pull that never produced a stream lapses.
        #expect(await tracker.claim("b", from: bob, now: start.addingTimeInterval(31)))
        await tracker.finish("b")
        #expect(await !tracker.isPulling("b", from: bob))
    }

    @Test("A wanted blob is announced once per interval, and not while it's being pulled")
    func announcements() async {
        let tracker = KeepTalkingBlobPullTracker()
        let start = Date()
        #expect(await tracker.dueForAnnouncement(["a", "b", "a"], now: start) == ["a", "b"])
        #expect(await tracker.dueForAnnouncement(["a"], now: start.addingTimeInterval(5)) == [])
        _ = await tracker.claim("b", from: UUID(), now: start.addingTimeInterval(11))
        #expect(await tracker.dueForAnnouncement(["a", "b"], now: start.addingTimeInterval(11)) == ["a"])
    }

    @Test("The outbox snapshots the file and serves it only to its recipient until it expires")
    func outbox() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = KeepTalkingOneTimeBlobOutbox(directory: directory.appendingPathComponent("outbox"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.txt")
        try Data("hello".utf8).write(to: source)

        let recipient = UUID()
        let start = Date()
        let (transferID, byteCount) = try await outbox.hold(
            fileURL: source, key: SymmetricKey(size: .bits256), recipient: recipient, mimeType: "text/plain", now: start
        )
        #expect(byteCount == 5)
        // The producer deleting its file doesn't matter: the outbox holds a copy.
        try FileManager.default.removeItem(at: source)

        #expect(await outbox.entry(for: transferID, requester: UUID(), now: start) == nil)
        let entry = try #require(await outbox.entry(for: transferID, requester: recipient, now: start))
        #expect(try Data(contentsOf: entry.fileURL) == Data("hello".utf8))

        await outbox.sweep(now: start.addingTimeInterval(KeepTalkingOneTimeBlobOutbox.lifetime + 1))
        #expect(await outbox.entry(for: transferID, requester: recipient) == nil)
        #expect(!FileManager.default.fileExists(atPath: entry.fileURL.path))
    }

    @Test("The assembler takes one pull per transfer; a broken pull can be retried")
    func assemblerPulls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let assembler = KeepTalkingOneTimeBlobAssembler(baseDirectory: directory)
        let transferID = UUID()
        let holder = UUID()

        #expect(await assembler.beginPull(transferID, from: holder))
        #expect(await !assembler.beginPull(transferID, from: holder))
        #expect(await assembler.isPulling(transferID, from: holder))
        await assembler.appendChunk(transferID: transferID, chunkIndex: 0, payload: Data([1]))

        await assembler.pullFailed(transferID, error: KeepTalkingOneTimeBlobError.transferFailed(transferID, "reset"))
        #expect(await assembler.beginPull(transferID, from: holder))
        await assembler.appendChunk(transferID: transferID, chunkIndex: 0, payload: Data([1]))
        await assembler.appendChunk(transferID: transferID, chunkIndex: 1, payload: Data([2]))
        await assembler.markComplete(transferID: transferID, chunkCount: 2)

        try await assembler.awaitCompletion(transferID: transferID)
        #expect(
            try await assembler.orderedCiphertextChunks(transferID: transferID).map(\.data) == [Data([1]), Data([2])])
        // Done: no second pull.
        #expect(await !assembler.beginPull(transferID, from: holder))
    }
}
