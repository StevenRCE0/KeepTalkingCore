import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

#if os(macOS)

/// LIVE end-to-end coverage of KTPP over the real Unix socket: the actual
/// `KeepTalkingPluginHost` actor on one side, the actual Python plugin SDK
/// (`CompanionRuntime/keeptalking_plugin.py`) as a subprocess on the other.
///
/// Proves the full loop the design doc promises: connect → kind
/// registration carrying `objects`/capabilities → a call whose handler streams
/// the source in and the result out through slot resources → elucidations
/// arrive live and aggregated → ACT is denied without consent, served with it.
///
/// Runs on the Companion's own runtime interpreter (`companion.py
/// --runtime-python` sets it up; `KT_E2E_PYTHON` overrides). Skipped (not
/// failed) unless that interpreter has grpcio and the CompanionRuntime checkout
/// beside this package speaks KTPP.
@Suite(.serialized)
struct PluginSocketE2ETests {

    // MARK: Environment

    /// The CompanionRuntime submodule checkout inside the app repo, resolved
    /// relative to this source file.
    static let companionRuntimeDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // KeepTalkingSDKTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // KeepTalking
        .deletingLastPathComponent()  // workspace root
        .appendingPathComponent(
            "KeepTalkingApp/KeepTalkingCompanion/CompanionRuntime", isDirectory: true)

    /// The Companion runtime's interpreter, from the developer's REAL home
    /// (resolved before any test isolates `HOME`).
    static let runtimePython: String =
        ProcessInfo.processInfo.environment["KT_E2E_PYTHON"]
        ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".keeptalking-plugin/kt-companion/venv/bin/python").path

    static let environmentReady: Bool = {
        guard
            FileManager.default.fileExists(
                atPath: companionRuntimeDir.appendingPathComponent("plugin_host.py").path),
            FileManager.default.isExecutableFile(atPath: runtimePython)
        else { return false }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: runtimePython)
        probe.arguments = [
            "-c",
            "import sys, grpc; sys.path.insert(0, sys.argv[1]); import keeptalking_plugin as k; "
                + "sys.exit(0 if k.PROTOCOL_VERSION == \(KTPPWire.protocolVersion) else 1)",
            companionRuntimeDir.path,
        ]
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
    /// real `plugin_host.py` with an ISOLATED $HOME (the SDK keeps its state in
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
        try await host.start()

        let plugin = Process()
        plugin.executableURL = URL(fileURLWithPath: runtimePython)
        plugin.arguments = [
            companionRuntimeDir.appendingPathComponent("plugin_host.py").path,
            "--module", moduleFile.path,
            "--socket", socketPath,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        plugin.environment = environment
        // As the companion does: plugin_host.py exits on stdin EOF, so hand it
        // a pipe we own instead of whatever stdin the test runner has.
        plugin.standardInput = Pipe()
        // Keep output visible in the test log when something goes sideways.
        plugin.standardOutput = FileHandle.standardOutput
        plugin.standardError = FileHandle.standardOutput
        try plugin.run()

        return Harness(host: host, plugin: plugin, scratch: scratch)
    }

    /// Waits until the catalog row has landed in the catalogue store (kept as a
    /// guard: the row is written as the plugin connects, before its kinds).
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
        "markitdown plugin over the live socket: open, declare, convert into a slot",
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
        #expect(kind.declaredCapabilities.contains(.act))

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
        #expect(outcome.record.verdict == .unattested)
        #expect(outcome.elucidations.contains { $0.contains("Converting notes.txt") })
        #expect(live.notes.contains { $0.contains("Converting notes.txt") })

        // Slot written through the SDK stream (mock conversion — markitdown
        // itself isn't provisioned in the test interpreter, which is the point:
        // the transport, not the converter, is under test).
        let slotText = try String(contentsOf: slotPath, encoding: .utf8)
        #expect(slotText.contains("notes.txt"))
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
    /// A probe plugin that records `plugin.ui.reveal` by writing a marker file
    /// under its (scratch) HOME, optionally claiming the companion role and
    /// optionally installing a reveal handler at all.
    private static func revealProbeModule(role: String?, handles: Bool) throws -> URL {
        let module = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kt-reveal-probe-\(UUID().uuidString.prefix(8)).py")
        let roleArgument = role.map { ", role=\($0.debugDescription)" } ?? ""
        let handlerLine =
            handles
            ? "plugin.on_reveal = lambda: (Path.home() / 'revealed').write_text('1')"
            : "pass"
        try """
        import sys
        from pathlib import Path
        sys.path.insert(0, \(companionRuntimeDir.path.debugDescription))
        from keeptalking_plugin import Plugin


        def make_plugin():
            plugin = Plugin(name="RevealProbe", vendor="test", version="0.0.1"\(roleArgument))

            @plugin.kind("reveal-probe", description="exists so the catalog registers a kind")
            async def noop(args, ctx):
                return "noop"

            \(handlerLine)
            return plugin


        if __name__ == "__main__":
            make_plugin().run()
        """.data(using: .utf8)!.write(to: module)
        return module
    }

    /// Runs `revealCompanion()` against one probe plugin; returns the host's
    /// verdict and whether the plugin actually saw the reveal.
    private static func revealOutcome(role: String?, handles: Bool) async throws
        -> (acknowledged: Bool, pluginRevealed: Bool)
    {
        let module = try revealProbeModule(role: role, handles: handles)
        defer { try? FileManager.default.removeItem(at: module) }
        let harness = try await startHarness(moduleFile: module)
        defer { Task { await harness.tearDown() } }
        let catalogID = try await harness.host.waitForKind("reveal-probe", timeout: 30)
        try await waitForCatalogue(harness.host, catalogID: catalogID)
        let acknowledged = await harness.host.revealCompanion(timeout: 5)
        let marker = harness.scratch.appendingPathComponent("home/revealed")
        return (acknowledged, FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(
        "plugin.ui.reveal: reaches a companion's handler; declined or ignored otherwise",
        .enabled(if: PluginSocketE2ETests.environmentReady))
    func revealCompanionRoundTrip() async throws {
        let companion = try await Self.revealOutcome(role: "companion", handles: true)
        #expect(companion.acknowledged)
        #expect(companion.pluginRevealed)

        // A companion with no UI attached says `unhandled`: the host reports
        // false so the app can launch the companion instead.
        let headless = try await Self.revealOutcome(role: "companion", handles: false)
        #expect(!headless.acknowledged)
        #expect(!headless.pluginRevealed)

        // An ordinary plugin is never a target, even with a handler installed.
        let plain = try await Self.revealOutcome(role: nil, handles: true)
        #expect(!plain.acknowledged)
        #expect(!plain.pluginRevealed)
    }

    @Test(
        "plugin.scope.options: declared live keys are asked, answers trimmed, refusals surfaced",
        .enabled(if: PluginSocketE2ETests.environmentReady))
    func scopeOptionsRoundTrip() async throws {
        let module = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kt-options-probe-\(UUID().uuidString.prefix(8)).py")
        try """
        import sys
        sys.path.insert(0, \(Self.companionRuntimeDir.path.debugDescription))
        from keeptalking_plugin import Plugin, scope_option


        def make_plugin():
            plugin = Plugin(name="OptionsProbe", vendor="test", version="0.0.1")

            @plugin.kind(
                "options-probe",
                description="scope choices",
                scope_schema={
                    "apps": {"type": "array", "items": {"type": "string"}},
                    "mode": {"type": "string", "enum": ["fast", "safe"]},
                    "broken": {"type": "string"},
                    "free": {"type": "string"},
                },
            )
            async def probe(args, ctx):
                return "ok"

            @plugin.scope_options("options-probe", "apps", allows_custom=False)
            async def apps(request):
                options = [
                    scope_option("com.example.one", "One", group="Open now",
                                 app="com.example.one", caution="careful"),
                    scope_option("com.example.two", "Two\\nlines " + "x" * 300),
                    {"value": {"nested": True}, "label": "not a scalar"},
                    scope_option("echo", f"{request.query}|{request.scope.get('mode')}"),
                ]
                return options

            @plugin.scope_options("options-probe", "broken")
            async def broken(request):
                raise RuntimeError("dependency missing")

            return plugin
        """.data(using: .utf8)!.write(to: module)
        defer { try? FileManager.default.removeItem(at: module) }

        let harness = try await Self.startHarness(moduleFile: module)
        defer { Task { await harness.tearDown() } }
        let host = harness.host
        let catalogID = try await host.waitForKind("options-probe", timeout: 30)
        try await Self.waitForCatalogue(host, catalogID: catalogID)

        // The declaration carries the keyword; fixed enums parse without it.
        let summary = try #require(
            await host.catalogue.summary(catalogID: catalogID, kindName: "options-probe"))
        let apps = try #require(summary.scopeOptionsSpec(for: "apps"))
        #expect(apps.isLive && apps.isMultiple && !apps.allowsCustom)
        let mode = try #require(summary.scopeOptionsSpec(for: "mode"))
        #expect(!mode.isLive && !mode.allowsCustom)
        #expect(mode.fixedChoices == [.string("fast"), .string("safe")])
        #expect(summary.scopeOptionsSpec(for: "free") == nil)

        let options = try await host.scopeOptions(
            catalogID: catalogID, kindName: "options-probe", key: "apps",
            scope: ["mode": .string("safe")], query: "sa")
        #expect(
            options.map(\.value) == [
                .string("com.example.one"), .string("com.example.two"), .string("echo"),
            ])
        #expect(options[0].group == "Open now")
        #expect(options[0].icon?.app == "com.example.one")
        #expect(options[0].caution == "careful")
        #expect(options[1].label.count == 120 && !options[1].label.contains("\n"))
        #expect(options[2].label == "sa|safe")

        // A provider's own failure comes back as the plugin's message.
        let refusal = await #expect(throws: KTPPHostError.self) {
            try await host.scopeOptions(
                catalogID: catalogID, kindName: "options-probe", key: "broken")
        }
        #expect(refusal?.errorDescription == "dependency missing")

        // Keys without live options are never asked.
        await #expect(throws: KTPPHostError.self) {
            try await host.scopeOptions(
                catalogID: catalogID, kindName: "options-probe", key: "free")
        }
    }

    @Test(
        "declared resources: catalogued with the kind, read as MCP contents; call-returned contents map into requested outputs",
        .enabled(if: PluginSocketE2ETests.environmentReady))
    func declaredResourcesRoundTrip() async throws {
        let module = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kt-resource-probe-\(UUID().uuidString.prefix(8)).py")
        try """
        import base64
        import sys
        sys.path.insert(0, \(Self.companionRuntimeDir.path.debugDescription))
        from keeptalking_plugin import Plugin, resource

        PNG = base64.b64encode(b"\\x89PNG").decode()


        def make_plugin():
            plugin = Plugin(name="ResourceProbe", vendor="test", version="0.0.1")

            @plugin.kind(
                "resource-probe",
                description="declares resources, returns files",
                resources=[
                    resource("mem://guide.md", "guide.md", mime_type="text/markdown"),
                    resource("mem://pixel.png", "pixel.png", mime_type="image/png"),
                    resource("mem://broken.md", "broken.md"),
                ],
            )
            async def probe(args, ctx):
                return [
                    {"type": "text", "text": "done"},
                    {"type": "resource", "resource": {
                        "uri": "mem://report.txt", "mimeType": "text/plain", "text": "report"}},
                    {"type": "resource", "resource": {
                        "uri": "mem://shot.png", "mimeType": "image/png", "blob": PNG}},
                    {"type": "image", "data": PNG, "mimeType": "image/png"},
                    {"type": "resource_link", "uri": "mem://guide.md", "name": "guide.md"},
                ]

            @plugin.resource_reader
            async def read(uri):
                if uri == "mem://guide.md":
                    return [{"uri": uri, "mimeType": "text/markdown", "text": "# Guide\\nhi"}]
                if uri == "mem://pixel.png":
                    return [{"uri": uri, "mimeType": "image/png", "blob": PNG}]
                raise ValueError("cannot read " + uri)

            return plugin
        """.data(using: .utf8)!.write(to: module)
        defer { try? FileManager.default.removeItem(at: module) }

        let harness = try await Self.startHarness(moduleFile: module)
        defer { Task { await harness.tearDown() } }
        let host = harness.host
        let catalogID = try await host.waitForKind("resource-probe", timeout: 30)
        try await Self.waitForCatalogue(host, catalogID: catalogID)

        // Declared beside the tools, catalogued with the kind.
        let declared = await host.catalogue.kind(catalogID: catalogID, kindName: "resource-probe")?
            .resources?.map(\.uri)
        #expect(declared == ["mem://guide.md", "mem://pixel.png", "mem://broken.md"])

        // Read: MCP `resources/read` contents, verbatim.
        let guide = try await host.readResource(
            catalogID: catalogID, kindName: "resource-probe", uri: "mem://guide.md")
        #expect(guide.first?.text == "# Guide\nhi")
        let pixel = try await host.readResource(
            catalogID: catalogID, kindName: "resource-probe", uri: "mem://pixel.png")
        #expect(pixel.first?.blob.flatMap { Data(base64Encoded: $0) } == Data([0x89, 0x50, 0x4E, 0x47]))

        // Undeclared uris are refused host-side; a reader's refusal is its message.
        await #expect(throws: KTPPHostError.self) {
            try await host.readResource(
                catalogID: catalogID, kindName: "resource-probe", uri: "mem://secret")
        }
        let refusal = await #expect(throws: KTPPHostError.self) {
            try await host.readResource(
                catalogID: catalogID, kindName: "resource-probe", uri: "mem://broken.md")
        }
        #expect(refusal?.errorDescription == "cannot read mem://broken.md")

        // Call IO maps to KTRM: every file the result carries becomes a resource.
        let outcome = try await host.callKind(
            catalogID: catalogID, kindName: "resource-probe", arguments: [:],
            instanceID: UUID.v7(), instanceScope: nil)
        let content = try JSONDecoder().decode(
            [Tool.Content].self, from: JSONEncoder().encode(outcome.content))
        #expect(
            KeepTalkingPluginHost.mappingGeneratedContents(content, into: nil, runDirectory: nil)
                == content)
        let png = Data([0x89, 0x50, 0x4E, 0x47])

        // Nothing requested: files go to the run's directory (delivered as
        // private OTBs); images stay visible beside their note; text stays inline.
        let runDirectory = harness.scratch.appendingPathComponent("run", isDirectory: true)
        let spilled = KeepTalkingPluginHost.mappingGeneratedContents(
            content, into: nil, runDirectory: runDirectory)
        #expect(try Data(contentsOf: runDirectory.appendingPathComponent("shot.png")) == png)
        #expect(try Data(contentsOf: runDirectory.appendingPathComponent("image-4.png")) == png)
        #expect(spilled.count == 7)
        #expect(spilled[1] == content[1])
        #expect(spilled[2] == content[2] && spilled[4] == content[3])
        guard case .text(let shotNote, _, _) = spilled[3], case .text(let imageNote, _, _) = spilled[5]
        else {
            Issue.record("generated files carry no note: \(spilled)")
            return
        }
        #expect(shotNote.contains("shot.png") && shotNote.contains("produced_resources"))
        #expect(imageNote.contains("image-4.png") && imageNote.contains("produced_resources"))
        #expect(spilled[6] == content[4])  // links stay links

        // Requested outputs claim them first: one file per single slot, the rest
        // into a collection.
        let fileSlot = harness.scratch.appendingPathComponent("slots/result")
        let collection = harness.scratch.appendingPathComponent("slots/files", isDirectory: true)
        let manifest = KTResourceManifest.build(
            grantedCandidates: [
                .init(
                    kind: .otb, id: UUID.v7(), path: fileSlot, direction: .write,
                    displayName: "result", isDirectory: false, objectName: "result"),
                .init(
                    kind: .otb, id: UUID.v7(), path: collection, direction: .write,
                    displayName: "files", isDirectory: true, objectName: "files"),
            ],
            umbrellaAttachmentsDir: nil)
        let mapped = KeepTalkingPluginHost.mappingGeneratedContents(
            content, into: manifest, runDirectory: runDirectory)
        #expect(try String(contentsOf: fileSlot, encoding: .utf8) == "report")
        #expect(try Data(contentsOf: collection.appendingPathComponent("shot.png")) == png)
        #expect(try Data(contentsOf: collection.appendingPathComponent("image-4.png")) == png)
        guard case .text(let report, _, _) = mapped[1], case .text(let shot, _, _) = mapped[3],
            case .text(let image, _, _) = mapped[5]
        else {
            Issue.record("requested outputs carry no note: \(mapped)")
            return
        }
        let resultURI = KTResourceManifest.resourceURI(handle: manifest.entries[0].envKey)
        let filesURI = KTResourceManifest.resourceURI(handle: manifest.entries[1].envKey)
        #expect(report.contains("report.txt") && report.contains(resultURI))
        #expect(shot.contains(filesURI + "/shot.png"))
        #expect(image.contains(filesURI + "/image-4.png"))
    }

    @Test("kt-resource:// URIs: arguments resolve to this call's paths, result paths map back")
    func resourceURIMapping() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kt-uri-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let output = root.appendingPathComponent("out")
        let shots = root.appendingPathComponent("shots", isDirectory: true)
        let input = root.appendingPathComponent("in.txt")
        let manifest = KTResourceManifest.build(
            grantedCandidates: [
                .init(
                    kind: .otb, id: UUID.v7(), path: output, direction: .write,
                    displayName: "result", isDirectory: false, objectName: "result"),
                .init(
                    kind: .otb, id: UUID.v7(), path: shots, direction: .write,
                    displayName: "shots", isDirectory: true, objectName: "shots"),
                .init(
                    kind: .otb, id: UUID.v7(), path: input, direction: .read,
                    displayName: "in.txt", isDirectory: false),
            ],
            umbrellaAttachmentsDir: nil)
        let (out, coll, inp) = (manifest.entries[0], manifest.entries[1], manifest.entries[2])

        #expect(KTResourceManifest.parseResourceURI("kt-resource://\(out.envKey)")?.handle == out.envKey)
        #expect(KTResourceManifest.parseResourceURI("kt-resource://x/../etc") == nil)
        #expect(KTResourceManifest.parseResourceURI("https://example.com") == nil)

        let resolved = try KeepTalkingPluginHost.resolvingResourceURIs(
            [
                "screenshot_out_file": .string("kt-resource://\(out.envKey)"),
                "files": .array([.string("kt-resource://\(inp.envKey.lowercased())")]),
                "nested": .object(["frame": .string("kt-resource://\(coll.envKey)/frame.png")]),
                "plain": .string("hello"),
            ],
            manifest: manifest)
        #expect(resolved["screenshot_out_file"] == .string(out.path!.path))
        #expect(resolved["files"] == .array([.string(inp.path!.path)]))
        #expect(resolved["nested"] == .object(["frame": .string(coll.path!.appendingPathComponent("frame.png").path)]))
        #expect(resolved["plain"] == .string("hello"))

        // Anything that is not one of this call's resources refuses the call.
        #expect(throws: KTPPHostError.self) {
            try KeepTalkingPluginHost.resolvingResourceURIs(
                ["f": .string("kt-resource://KT_OTB_NOT_THIS_CALL")], manifest: manifest)
        }
        #expect(throws: KTPPHostError.self) {
            try KeepTalkingPluginHost.resolvingResourceURIs(
                ["f": .string("kt-resource://\(out.envKey)/child.png")], manifest: manifest)
        }

        let back = KeepTalkingPluginHost.mappingResourcePaths(
            [
                .text(
                    text: "saved \(out.path!.path) and \(coll.path!.path)/frame.png",
                    annotations: nil, _meta: nil)
            ],
            manifest: manifest)
        guard case .text(let text, _, _) = back[0] else {
            Issue.record("expected text")
            return
        }
        #expect(text == "saved kt-resource://\(out.envKey) and kt-resource://\(coll.envKey)/frame.png")
    }

    @Test(
        "a plugin that drops mid-call fails the call at once, not at its timeout",
        .enabled(if: PluginSocketE2ETests.environmentReady))
    func droppedConnectionFailsInFlightCall() async throws {
        let module = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kt-hang-probe-\(UUID().uuidString.prefix(8)).py")
        try """
        import asyncio
        import sys
        sys.path.insert(0, \(Self.companionRuntimeDir.path.debugDescription))
        from keeptalking_plugin import Plugin


        def make_plugin():
            plugin = Plugin(name="HangProbe", vendor="test", version="0.0.1")

            @plugin.kind("hang-probe", description="never answers")
            async def hang(args, ctx):
                await asyncio.sleep(3600)

            return plugin
        """.data(using: .utf8)!.write(to: module)
        defer { try? FileManager.default.removeItem(at: module) }

        let harness = try await Self.startHarness(moduleFile: module)
        defer { Task { await harness.tearDown() } }
        let host = harness.host
        let catalogID = try await host.waitForKind("hang-probe", timeout: 30)

        let started = Date()
        let call = Task {
            try await host.callKind(
                catalogID: catalogID, kindName: "hang-probe", arguments: [:],
                instanceID: UUID.v7(), instanceScope: nil, timeout: 120)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        harness.plugin.terminate()

        let error = await #expect(throws: KTPPHostError.self) { try await call.value }
        guard case .notConnected? = error else {
            Issue.record("expected notConnected, got \(String(describing: error))")
            return
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

#endif
