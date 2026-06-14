import Foundation
import Testing

@testable import KeepTalkingSDK

/// Covers the consume-once vs re-feedable distinction that fixes the missing
/// `$KT_OTB` env var: a PRODUCED `.otb` output (stageLocalFile) must survive
/// consumption so it can be re-fed into a later action (A→B chaining), while an
/// ephemeral input relay (default register) is destroyed on first consume.
struct KeepTalkingStagedFileStoreTests {
    private func makeStore() -> (store: KeepTalkingStagedFileStore, base: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kt-staged-test-\(UUID().uuidString)", isDirectory: true)
        return (KeepTalkingStagedFileStore(baseDirectory: base), base)
    }

    private func writeTemp(_ contents: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kt-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("file.txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("a re-feedable produced OTB survives discardIfConsumable and can be re-fed")
    func producedOTBSurvivesConsumption() async throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let caller = UUID()
        let source = try writeTemp("PRODUCED-OTB-BODY")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let staged = await store.stageLocalFile(
            at: source, filename: "report.pdf", callerNodeID: caller)
        let handle = try #require(staged?.handle)

        // First consume: the post-call cleanup runs discardIfConsumable…
        await store.discardIfConsumable(handle: handle)

        // …and the produced output is STILL there — re-feedable into a later action.
        let after = await store.file(handle: handle, callerNodeID: caller)
        #expect(after != nil)
        #expect(after?.filename == "report.pdf")

        // It actually copies out again (the chaining path), proving bytes survive.
        let dest = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kt-refeed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let copied = try await store.copyStagedFile(
            handle: handle, callerNodeID: caller, into: dest)
        #expect(copied != nil)
    }

    @Test("a consume-once input relay is discarded by discardIfConsumable")
    func relayIsConsumedOnce() async throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let caller = UUID()

        // An ephemeral relay: register with the default (consumeOnUse: true).
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("relay.bin")
        try "RELAY".write(to: url, atomically: true, encoding: .utf8)
        let handle = UUID()
        await store.register(
            handle: handle, url: url, callerNodeID: caller,
            filename: "relay.bin", byteCount: 5)

        #expect(await store.file(handle: handle, callerNodeID: caller) != nil)

        // First consume destroys it (the historical relay behavior).
        await store.discardIfConsumable(handle: handle)
        #expect(await store.file(handle: handle, callerNodeID: caller) == nil)
    }
}
