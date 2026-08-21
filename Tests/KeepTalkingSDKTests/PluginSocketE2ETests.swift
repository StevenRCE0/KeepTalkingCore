import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

#if os(macOS)

/// LIVE end-to-end coverage of KTPP v1.1 over the real Unix socket: the actual
/// `KeepTalkingPluginHost` actor on one side, the actual Python plugin SDK
/// (`CompanionRuntime/keeptalking_plugin.py`) as a subprocess on the other.
///
/// Proves the full loop the design doc promises: pair (auto-approved) → kind
/// registration carrying `objects`/`usesACT` → a call whose signed
/// authorization binds `resourcesHash` (the Python side REJECTS the call if
/// the hash doesn't match what it received) → handler streams the source in
/// and the result out through slot resources → elucidations arrive live and
/// aggregated → ACT is denied without consent, served with it → the receipt
/// verifies and the ledger stays sound.
///
/// Skipped (not failed) on machines without `python3` + `cryptography` or the
/// CompanionRuntime checkout beside this package.
@Suite(.serialized)
struct PluginSocketE2ETests {

    // MARK: Environment

    /// `<workspace>/CompanionRuntime`, resolved relative to this source file.
    static let companionRuntimeDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // KeepTalkingSDKTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // KeepTalking
        .deletingLastPathComponent()  // workspace root
        .appendingPathComponent("CompanionRuntime", isDirectory: true)

    static let environmentReady: Bool = {
        guard
            FileManager.default.fileExists(
                atPath: companionRuntimeDir.appendingPathComponent("plugin_host.py").path)
        else { return false }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["python3", "-c", "import cryptography"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            return probe.terminationStatus == 0
        } catch {
            return false
        }
    }()

    // MARK: Harness

    /// Collects live elucidation callbacks across concurrency domains.
    final class NoteCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ note: String) {
            lock.lock()
            storage.append(note)
            lock.unlock()
        }
        var notes: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    struct Harness {
        let host: KeepTalkingPluginHost
        let plugin: Process
        let scratch: URL

        func tearDown() async {
            plugin.terminate()
            await host.stop()
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    /// Starts a host on a fresh socket and launches `moduleFile` through the
    /// real `plugin_host.py` with an ISOLATED $HOME (the SDK keys/pairs into
    /// `~/.keeptalking-plugin/…`, which must never touch the developer's real
    /// companion state).
    static func startHarness(moduleFile: URL) async throws -> Harness {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kt-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let socketPath = scratch.appendingPathComponent("ktpp.sock").path

        let host = KeepTalkingPluginHost(
            hostNodeID: UUID.v7(),
            socketPath: socketPath,
            catalogue: KeepTalkingPluginCatalogueStore(fileURL: nil))
        await host.setPairingApprovalHandler { _, _ in true }
        try await host.start()

        let plugin = Process()
        plugin.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        plugin.arguments = [
            "python3",
            companionRuntimeDir.appendingPathComponent("plugin_host.py").path,
            "--module", moduleFile.path,
            "--socket", socketPath,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        plugin.environment = environment
        // Keep output visible in the test log when something goes sideways.
        plugin.standardOutput = FileHandle.standardOutput
        plugin.standardError = FileHandle.standardOutput
        try plugin.run()

        return Harness(host: host, plugin: plugin, scratch: scratch)
    }

    /// Waits until pairing has landed in the catalogue store (commitPairing
    /// persists on a detached task, so the row can trail the session by a beat).
    static func waitForCatalogue(
        _ host: KeepTalkingPluginHost, catalogID: UUID, timeout: TimeInterval = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await host.catalogue.catalogue(catalogID) != nil { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw KTPPHostError.timeout("catalogue row for \(catalogID.uuidString.lowercased())")
    }

    /// Deliberately the ADVERSE naming shape from the 2026-08-17 live run: the
    /// source is a catch-all context attachment (no objectName) and the slot
    /// carries a caller-chosen label, NOT the kind's declared "markdown" — the
    /// SDK's sole-entry fallbacks must absorb both.
    static func sampleManifest(
        scratch: URL, sourceName: String, sourceContent: String
    ) throws -> (manifest: KTResourceManifest, sourcePath: URL, slotPath: URL) {
        let sourcePath = scratch.appendingPathComponent(sourceName)
        try sourceContent.data(using: .utf8)!.write(to: sourcePath)
        let slotPath = scratch.appendingPathComponent("markdown")
        let manifest = KTResourceManifest.build(
            grantedCandidates: [
                .init(
                    kind: .attachment, id: UUID.v7(), path: sourcePath, direction: .read,
                    displayName: sourceName, isDirectory: false, objectName: nil),
                .init(
                    kind: .otb, id: UUID.v7(), path: slotPath, direction: .write,
                    displayName: "catalogue_markdown", isDirectory: false,
                    objectName: "catalogue_markdown"),
            ],
            umbrellaAttachmentsDir: nil)
        return (manifest, sourcePath, slotPath)
    }

    // MARK: Tests

    @Test(
        "markitdown plugin over the live socket: pair, declare, convert into a slot",
        .enabled(if: PluginSocketE2ETests.environmentReady))
    func markitdownRoundTrip() async throws {
        let harness = try await Self.startHarness(
            moduleFile: Self.companionRuntimeDir
                .appendingPathComponent("plugins/markitdown_plugin.py"))
        defer { Task { await harness.tearDown() } }

        let catalogID = try await harness.host.waitForKind("markitdown-convert", timeout: 30)

        // The declaration crossed the wire with its file objects + disclosure.
        let summary = await harness.host.listCatalogs()
            .first { $0.catalogID == catalogID }
        let kind = try #require(
            summary?.kinds?.kinds.first { $0.kindName == "markitdown-convert" })
        #expect(kind.objects?.count == 2)
        #expect(kind.objects?.first?.direction == "input")
        #expect(kind.usesACT == true)

        let (manifest, _, slotPath) = try Self.sampleManifest(
            scratch: harness.scratch, sourceName: "notes.txt",
            sourceContent: "hello e2e world")

        // Instance scope enforced by the handler, bound by the signed hash.
        let denied = try await harness.host.callKind(
            catalogID: catalogID,
            kindName: "markitdown-convert",
            arguments: [:],
            instanceID: UUID.v7(),
            instanceScope: .object(["allowedExtensions": .array([.string(".pdf")])]),
            manifest: manifest)
        #expect(denied.isError)

        // The good call: resourcesHash verifies plugin-side (a mismatch would
        // come back as an error), the handler streams the source, writes the
        // slot, and narrates.
        let live = NoteCollector()
        let outcome = try await harness.host.callKind(
            catalogID: catalogID,
            kindName: "markitdown-convert",
            arguments: [:],
            instanceID: UUID.v7(),
            instanceScope: nil,
            manifest: manifest,
            onElucidation: { message, _ in live.append(message) })
        #expect(!outcome.isError)
        #expect(outcome.receiptStatus == .valid)
        #expect(outcome.elucidations.contains { $0.contains("Converting notes.txt") })
        #expect(live.notes.contains { $0.contains("Converting notes.txt") })

        // Slot written through the SDK stream (mock conversion — markitdown
        // itself isn't provisioned in the test interpreter, which is the point:
        // the transport, not the converter, is under test).
        let slotText = try String(contentsOf: slotPath, encoding: .utf8)
        #expect(slotText.contains("notes.txt"))

        // The signed authorization carried the resource binding, and the
        // dual-signed ledger stays sound end to end.
        if case .object(let fields) = outcome.record.authorization {
            #expect(fields["resourcesHash"] != nil)
        } else {
            Issue.record("authorization is not an object")
        }
        let report = await harness.host.verifyLedger()
        #expect(report.isSound)
    }

    @Test(
        "host.act over the live socket: denied without consent, served with it",
        .enabled(if: PluginSocketE2ETests.environmentReady))
    func actConsentRoundTrip() async throws {
        // A minimal probe plugin, generated fresh so this test is
        // self-contained: elucidates, then asks the host for one ACT turn with
        // its source resource attached, writing the reply into its slot.
        let scratchModule = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kt-act-probe-\(UUID().uuidString.prefix(8)).py")
        try """
        import sys
        sys.path.insert(0, \(Self.companionRuntimeDir.path.debugDescription))
        from keeptalking_plugin import ActDenied, Plugin, file_in, file_out


        def make_plugin():
            plugin = Plugin(name="ActProbe", vendor="test", version="0.0.1")

            async def run_probe(ctx):
                ctx.elucidate("probe running")
                source = ctx.resources.input("source")
                slot = ctx.resources.output("markdown")
                try:
                    act = await ctx.act(
                        "polish", attachments=[source.handle], timeout=30)
                    slot.write_text(act.text)
                    return "acted:" + act.model
                except ActDenied as denial:
                    slot.write_text("denied")
                    return "denied:" + str(denial)

            @plugin.kind(
                "act-probe",
                description="asks the host ACT agent to rewrite its source",
                objects=[file_in("source", "input"), file_out("markdown", "output")],
                capabilities=["act"],
            )
            async def probe(args, ctx):
                return await run_probe(ctx)

            @plugin.kind(
                "act-mute",
                description="identical probe that never declared the act capability",
                objects=[file_in("source", "input"), file_out("markdown", "output")],
            )
            async def mute(args, ctx):
                return await run_probe(ctx)

            @plugin.kind(
                "ui-probe",
                description="asks the host to open the add-action UI",
            )
            async def ui(args, ctx):
                result = await plugin.request_open_add_action(
                    kind_name="act-probe", plugin_name="ActProbe", timeout=10)
                return "ui:" + str(result.get("status"))

            return plugin


        if __name__ == "__main__":
            make_plugin().run()
        """.data(using: .utf8)!.write(to: scratchModule)
        defer { try? FileManager.default.removeItem(at: scratchModule) }

        let harness = try await Self.startHarness(moduleFile: scratchModule)
        defer { Task { await harness.tearDown() } }

        let catalogID = try await harness.host.waitForKind("act-probe", timeout: 30)
        try await Self.waitForCatalogue(harness.host, catalogID: catalogID)

        let seenAttachments = NoteCollector()
        await harness.host.setACTHandler { request, context in
            for attachment in request.attachments {
                let content =
                    (try? String(contentsOf: attachment.path, encoding: .utf8)) ?? "<unreadable>"
                seenAttachments.append("\(attachment.handle):\(content)")
            }
            #expect(context.catalogName == "ActProbe")
            return KTPPActResult(text: "# polished by host", model: "test-model")
        }

        func callProbe(
            kind: String = "act-probe", instanceScope: Value? = nil
        ) async throws -> (KTPPCallOutcome, String) {
            let (manifest, _, slotPath) = try Self.sampleManifest(
                scratch: harness.scratch, sourceName: "draft-\(UUID().uuidString.prefix(4)).md",
                sourceContent: "raw draft")
            let outcome = try await harness.host.callKind(
                catalogID: catalogID,
                kindName: kind,
                arguments: [:],
                instanceID: UUID.v7(),
                instanceScope: instanceScope,
                manifest: manifest)
            return (outcome, (try? String(contentsOf: slotPath, encoding: .utf8)) ?? "")
        }

        // Consent OFF (the default): the turn is refused with the typed code,
        // the plugin degrades, the call itself still succeeds.
        let (deniedOutcome, deniedSlot) = try await callProbe()
        #expect(!deniedOutcome.isError)
        #expect(deniedSlot == "denied")
        #expect(deniedOutcome.record.hostActUsage == nil)

        // Consent ON: the handler runs with the attached resource's content,
        // the reply lands in the slot, and the spend is on the record.
        await harness.host.catalogue.setAllowsACT(true, catalogID: catalogID)
        let (servedOutcome, servedSlot) = try await callProbe()
        #expect(!servedOutcome.isError)
        #expect(servedSlot == "# polished by host")
        #expect(servedOutcome.record.hostActUsage?.requests == 1)
        #expect(seenAttachments.notes.contains { $0.hasSuffix(":raw draft") })
        // Both the plugin's own note and the auto-traced turn are aggregated.
        #expect(servedOutcome.elucidations.contains("probe running"))
        #expect(servedOutcome.elucidations.contains { $0.hasPrefix("AI turn:") })

        // Capability gates hold even WITH consent: a kind that never declared
        // `act`, and an instance whose scope narrowed it away, are both denied.
        let (muteOutcome, muteSlot) = try await callProbe(kind: "act-mute")
        #expect(!muteOutcome.isError)
        #expect(muteSlot == "denied")
        #expect(muteOutcome.record.hostActUsage == nil)
        let (narrowedOutcome, narrowedSlot) = try await callProbe(
            instanceScope: .object(["capabilities": .array([])]))
        #expect(!narrowedOutcome.isError)
        #expect(narrowedSlot == "denied")
        #expect(narrowedOutcome.record.hostActUsage == nil)

        let report = await harness.host.verifyLedger()
        #expect(report.isSound)

        // Reverse-direction UI request: the plugin asks the host to open the
        // add-action sheet; the injected handler must see the names and the
        // plugin must get an ok verdict back.
        let uiRequests = NoteCollector()
        await harness.host.setAddActionUIHandler { kindName, pluginName in
            uiRequests.append("\(kindName ?? "-")/\(pluginName ?? "-")")
        }
        let (uiOutcome, _) = try await callProbe(kind: "ui-probe")
        #expect(!uiOutcome.isError)
        if case .array(let content) = uiOutcome.content,
            case .object(let first)? = content.first,
            case .string(let text)? = first["text"]
        {
            #expect(text == "ui:ok")
        } else {
            Issue.record("unexpected ui-probe content shape")
        }
        #expect(uiRequests.notes == ["act-probe/ActProbe"])
    }
}

#endif
