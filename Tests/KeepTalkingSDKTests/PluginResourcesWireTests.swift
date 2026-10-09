import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

/// KTPP resources: the manifest → wire projection, its canonical-JSON form,
/// and the kind-object → descriptor materialization that gates file IO for
/// Catalogue (plugin) instances. See DESIGN_PLUGIN_RESOURCES_ACT.md §3.
struct PluginResourcesWireTests {

    /// An encodable payload as the JSON value a signing attestor would see.
    private func jsonValue(_ payload: some Encodable) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(payload))
    }

    private func sampleManifest(
        workspace: URL = URL(fileURLWithPath: "/tmp/kt-test-workspace")
    ) -> KTResourceManifest {
        let sourceID = UUID(uuidString: "5B2A93C4-1F0E-4D6A-A1B2-C3D4E5F60718")!
        let slotID = UUID(uuidString: "0198F00D-AAAA-7BBB-8CCC-DDDDEEEE0001")!
        return KTResourceManifest.build(
            grantedCandidates: [
                .init(
                    kind: .attachment,
                    id: sourceID,
                    path: URL(fileURLWithPath: "/tmp/kt-test-stage/report.pdf"),
                    direction: .read,
                    displayName: "report.pdf",
                    isDirectory: false,
                    objectName: "source"),
                .init(
                    kind: .otb,
                    id: slotID,
                    path: workspace.appendingPathComponent("markdown"),
                    direction: .write,
                    displayName: "markdown",
                    isDirectory: false,
                    objectName: "markdown"),
            ],
            umbrellaAttachmentsDir: nil)
    }

    @Test("wire entries are the 1:1 projection of manifest entries — handle IS envKey")
    func projection() throws {
        let manifest = sampleManifest()
        let resources = try #require(KTPPResources(manifest: manifest))
        #expect(resources.entries.count == manifest.entries.count)

        for (wire, entry) in zip(resources.entries, manifest.entries) {
            #expect(wire.handle == entry.envKey)
            #expect(wire.kind == entry.kind.agentFamily)
            #expect(wire.name == entry.displayName)
            #expect(wire.objectName == entry.objectName)
            #expect(wire.path == entry.path?.path)
            #expect(wire.isDirectory == entry.isDirectory)
        }
        #expect(resources.entries[0].direction == .read)
        #expect(resources.entries[1].direction == .write)
        // The read entry's path is the canonicalized staged path, verbatim —
        // the plugin SDK (not the wire) is the layer that hides it from
        // handler code.
        #expect(resources.entries[0].path?.hasSuffix("report.pdf") == true)
    }

    @Test("empty or absent manifests project to nil — the frame omits the field")
    func emptyProjection() {
        #expect(KTPPResources(manifest: nil) == nil)
        let empty = KTResourceManifest(entries: [], umbrellaAttachmentsDir: nil)
        #expect(KTPPResources(manifest: empty) == nil)
    }

    @Test("the resources block hashes deterministically and binds the concrete paths offered")
    func resourcesHash() throws {
        let a = try #require(KTPPResources(manifest: sampleManifest()))
        let b = try #require(KTPPResources(manifest: sampleManifest()))
        let hashA = try KeepTalkingCanonicalJSON.sha256Hex(try jsonValue(a))
        let hashB = try KeepTalkingCanonicalJSON.sha256Hex(try jsonValue(b))
        #expect(hashA == hashB)

        let other = try #require(
            KTPPResources(
                manifest: sampleManifest(
                    workspace: URL(fileURLWithPath: "/tmp/kt-other-workspace"))))
        let hashOther = try KeepTalkingCanonicalJSON.sha256Hex(try jsonValue(other))
        #expect(hashA != hashOther)
    }

    @Test("canonical JSON matches the Python SDK's byte for byte (conformance vector)")
    func crossLanguageHashVector() throws {
        // Pinned from CompanionRuntime/keeptalking_plugin.py's sha256_hex over
        // the identical block (non-ASCII name exercises ensure_ascii=False
        // parity). If this breaks, any attestation scheme signing across the
        // two SDKs breaks with it.
        let resources = KTPPResources(entries: [
            KTPPResourceEntry(
                handle: "KT_ATTACHMENT_5B2A93C41F0E4D6AA1B2C3D4E5F60718",
                kind: "attachment",
                direction: .read,
                name: "répört ✓.pdf",
                objectName: "source",
                path: "/private/tmp/kt-stage/répört ✓.pdf",
                isDirectory: false),
            KTPPResourceEntry(
                handle: "KT_OTB_0198F00DAAAA7BBB8CCCDDDDEEEE0001",
                kind: "otb",
                direction: .write,
                name: "markdown",
                objectName: "markdown",
                path: "/private/tmp/ws/markdown",
                isDirectory: false),
        ])
        let hash = try KeepTalkingCanonicalJSON.sha256Hex(try jsonValue(resources))
        #expect(hash == "861692e2ea1e6838f3dd41dc7079153000d6a661da6915e448607462b5f85f9a")
    }

    @Test("a call without resources or evidence decodes with both nil")
    func callRequestOptionalFields() throws {
        let json = """
            {"requestID":"r1","contextID":"c1","callerNodeID":"n1",
             "kindName":"k","arguments":{},"instance":{"id":"i1"}}
            """
        let request = try JSONDecoder().decode(
            KTPPCallRequest.self, from: Data(json.utf8))
        #expect(request.resources == nil)
        #expect(request.authorization == nil)
    }

    @Test("kind objects materialize onto the descriptor and flip acceptsFileInput")
    func descriptorMaterialization() throws {
        let kind = KTPPKindDeclaration(
            kindName: "markitdown-convert",
            displayName: "Convert to Markdown",
            indexDescription: "Convert documents to Markdown",
            inputSchema: nil,
            scopeSchema: nil,
            defaultScope: nil,
            subTools: nil,
            objects: [
                KTPPObjectDeclaration(
                    name: "source", direction: "input", description: "Document to convert"),
                KTPPObjectDeclaration(
                    name: "markdown", direction: "output", description: "Converted Markdown"),
                KTPPObjectDeclaration(name: "bogus", direction: "sideways"),
                KTPPObjectDeclaration(name: "   ", direction: "input"),
            ],
            capabilities: nil,
            remoteAuthorisable: true,
            blockingAuthorisation: false)
        let bundle = KeepTalkingPluginBundle(
            name: "MarkItDown", catalogID: UUID(), kindName: kind.kindName)

        let descriptor = KeepTalkingPluginHost.descriptor(for: bundle, kind: kind)
        let objects = try #require(descriptor.objects)
        // Unknown-direction and empty-name declarations are dropped, never
        // re-interpreted — a plugin bug must not widen file acceptance.
        #expect(objects.count == 2)
        #expect(objects[0].name == "source")
        #expect(objects[0].direction == .input)
        #expect(objects[1].name == "markdown")
        #expect(objects[1].direction == .output)

        let action = KeepTalkingAction(
            payload: .plugin(bundle), remoteAuthorisable: true, blockingAuthorisation: false)
        action.descriptor = descriptor
        #expect(action.acceptsFileInput)
    }

    @Test("binding: attachment input_handles and caller-named outputs reach declared objects")
    func pluginCallBinding() throws {
        // The live-run regression (2026-08-17): a caller passed a context
        // ATTACHMENT handle in input_handles and labeled its output
        // "catalogue_markdown" — the handler's lookups by declared objectName
        // ("source"/"markdown") both missed. Both bindings are host-side now.
        let kind = KTPPKindDeclaration(
            kindName: "markitdown-convert",
            displayName: "Convert",
            indexDescription: "",
            inputSchema: nil,
            scopeSchema: nil,
            defaultScope: nil,
            subTools: nil,
            objects: [
                KTPPObjectDeclaration(name: "source", direction: "input"),
                KTPPObjectDeclaration(name: "markdown", direction: "output"),
            ],
            capabilities: ["act"],
            remoteAuthorisable: nil,
            blockingAuthorisation: nil)
        let bundle = KeepTalkingPluginBundle(
            name: "MarkItDown", catalogID: UUID(), kindName: kind.kindName)
        let action = KeepTalkingAction(
            payload: .plugin(bundle), remoteAuthorisable: true, blockingAuthorisation: false)
        action.descriptor = KeepTalkingPluginHost.descriptor(for: bundle, kind: kind)

        let namedAttachment = UUID.v7()
        let bystander = UUID.v7()
        let call = KeepTalkingActionCall(
            action: UUID.v7(),
            inputHandles: [namedAttachment],
            outputHandles: [
                KeepTalkingActionOutputHandle(
                    name: "catalogue_markdown", persistence: .attachment)
            ])
        let staged = [
            KeepTalkingIOManager.StagedInputResource(
                id: namedAttachment,
                path: URL(fileURLWithPath: "/tmp/stage/catalogue.pdf"),
                displayName: "catalogue.pdf"),
            KeepTalkingIOManager.StagedInputResource(
                id: bystander,
                path: URL(fileURLWithPath: "/tmp/stage/unrelated.txt"),
                displayName: "unrelated.txt"),
        ]
        let binding = KeepTalkingIOManager.prepareCallBinding(
            action: action,
            call: call,
            attachments: staged,
            otbInputs: [],
            attachmentsDir: URL(fileURLWithPath: "/tmp/stage"),
            workspaceDir: URL(fileURLWithPath: "/tmp/ws"))

        // The handle the caller NAMED binds to the declared input; the other
        // context attachment stays catch-all.
        #expect(binding.inputs.first { $0.id == namedAttachment }?.objectName == "source")
        #expect(binding.inputs.first { $0.id == bystander }?.objectName == nil)
        // The caller-labeled output answers to the DECLARED objectName while
        // keeping the caller's label for display/filename/persistence.
        let slot = try #require(binding.outputs.first)
        #expect(slot.objectName == "markdown")
        #expect(slot.displayName == "catalogue_markdown")
        #expect(slot.kind == .attachment)

        // Skills keep the caller-label semantics unchanged.
        let skillAction = KeepTalkingAction(
            payload: .skill(
                KeepTalkingSkillBundle(
                    name: "s", indexDescription: "",
                    directory: URL(fileURLWithPath: "/tmp"))),
            remoteAuthorisable: true, blockingAuthorisation: false)
        skillAction.descriptor = nil  // Fluent @Field traps on unset access
        let skillBinding = KeepTalkingIOManager.prepareCallBinding(
            action: skillAction,
            call: call,
            attachments: [],
            otbInputs: [],
            attachmentsDir: nil,
            workspaceDir: URL(fileURLWithPath: "/tmp/ws"))
        #expect(skillBinding.outputs.first?.objectName == "catalogue_markdown")
    }

    @Test("host.act wire payloads round-trip the Python SDK's shapes")
    func actWireShapes() throws {
        // Exactly what ctx.act() emits (keys and all).
        let requestJSON = """
            {"requestID":"0198aaaa-bbbb-7ccc-8ddd-eeeeffff0001",
             "task":"Clean up this Markdown",
             "system":"Prefer ATX headings",
             "attachments":["KT_ATTACHMENT_5B2A93C41F0E4D6AA1B2C3D4E5F60718"],
             "expects":"json","maxOutputTokens":2048}
            """
        let request = try JSONDecoder().decode(
            KTPPActRequest.self, from: Data(requestJSON.utf8))
        #expect(request.task == "Clean up this Markdown")
        #expect(request.attachments?.count == 1)
        #expect(request.expects == "json")

        // Minimal request: optionals absent.
        let bare = try JSONDecoder().decode(
            KTPPActRequest.self,
            from: Data(#"{"requestID":"r","task":"t"}"#.utf8))
        #expect(bare.system == nil && bare.attachments == nil)

        // Result encodes without nil noise and round-trips.
        let result = KTPPActResult(text: "done", model: "gpt-5-codex")
        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(KTPPActResult.self, from: encoded)
        #expect(decoded.text == "done" && decoded.thinking == nil && decoded.usage == nil)

        // Elucidation notification payload.
        let note = try JSONDecoder().decode(
            KTPPActElucidation.self,
            from: Data(#"{"requestID":"r","message":"Converting report.pdf"}"#.utf8))
        #expect(note.detail == nil)
    }

    @Test("capabilities are a fixed vocabulary: unknown tokens drop")
    func capabilityVocabulary() throws {
        // What a newer/buggy plugin might declare: only "act" is recognized.
        let declared = try JSONDecoder().decode(
            KTPPKindDeclaration.self,
            from: Data(
                """
                {"kindName":"k","displayName":"K","indexDescription":"",
                 "capabilities":["act","teleport","filesystem"]}
                """.utf8))
        #expect(declared.declaredCapabilities == [.act])

        // Nothing declared means nothing.
        let bare = try JSONDecoder().decode(
            KTPPKindDeclaration.self,
            from: Data(#"{"kindName":"k","displayName":"K","indexDescription":""}"#.utf8))
        #expect(bare.declaredCapabilities.isEmpty)

        // Kind ceiling ∩ instance narrowing, fail-closed on both dials.
        #expect(KeepTalkingPluginHost.actCapabilityPermitted(kind: declared, instanceScope: nil))
        #expect(!KeepTalkingPluginHost.actCapabilityPermitted(kind: bare, instanceScope: nil))
        #expect(!KeepTalkingPluginHost.actCapabilityPermitted(kind: nil, instanceScope: nil))
        #expect(
            !KeepTalkingPluginHost.actCapabilityPermitted(
                kind: declared, instanceScope: .object(["capabilities": .array([])])))
        #expect(
            KeepTalkingPluginHost.actCapabilityPermitted(
                kind: declared,
                instanceScope: .object(["capabilities": .array([.string("act")])])))
    }

    @Test("act attachments render by content: text trims, binary embeds, images inline")
    func attachmentRendering() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kt-render-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Small text: verbatim.
        let small = scratch.appendingPathComponent("small.md")
        try Data("# hi".utf8).write(to: small)
        guard
            case .textBlock(let smallBlock) = KTPPActAttachmentRendering.render(
                handle: "KT_OTB_A", name: "small.md", path: small)
        else {
            Issue.record("expected textBlock")
            return
        }
        #expect(smallBlock.contains("# hi") && !smallBlock.contains("truncated"))

        // Oversized text: trimmed with a marker, never an error.
        let big = scratch.appendingPathComponent("big.txt")
        try Data(String(repeating: "y", count: KTPPActAttachmentRendering.textByteCap + 512).utf8)
            .write(to: big)
        guard
            case .textBlock(let bigBlock) = KTPPActAttachmentRendering.render(
                handle: "KT_OTB_B", name: "big.txt", path: big)
        else {
            Issue.record("expected textBlock")
            return
        }
        #expect(bigBlock.contains("truncated"))
        #expect(bigBlock.count < KTPPActAttachmentRendering.textByteCap + 512)

        // Non-UTF-8 binary: decodable trimmed base64 embed.
        let binary = scratch.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0xC3, 0x28] + Array(repeating: 0xAB, count: 128))
            .write(to: binary)
        guard
            case .textBlock(let binBlock) = KTPPActAttachmentRendering.render(
                handle: "KT_OTB_C", name: "blob.bin", path: binary)
        else {
            Issue.record("expected textBlock")
            return
        }
        #expect(binBlock.contains("base64"))
        let payload = try #require(binBlock.components(separatedBy: " ---\n").last)
        #expect(Data(base64Encoded: payload) != nil)

        // PNG: an inline image part on its own user message.
        let pngBytes = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
        let png = scratch.appendingPathComponent("pixel.png")
        try pngBytes.write(to: png)
        guard
            case .imageMessage(let lead, _) = KTPPActAttachmentRendering.render(
                handle: "KT_OTB_D", name: "pixel.png", path: png)
        else {
            Issue.record("expected imageMessage")
            return
        }
        #expect(lead.contains("KT_OTB_D") && lead.contains("image/png"))
    }

    @Test("ACT consent is per-catalog, fail-closed, and persisted")
    func actConsent() async {
        let store = KeepTalkingPluginCatalogueStore(fileURL: nil)
        let catalogID = UUID.v7()
        // Unknown catalog reads false; setting on it is a no-op.
        #expect(await store.allowsACT(catalogID) == false)
        await store.setAllowsACT(true, catalogID: catalogID)
        #expect(await store.allowsACT(catalogID) == false)

        await store.upsertCatalog(
            catalogID: catalogID,
            info: KTPPPluginInfo(name: "MarkItDown", vendor: "kt", version: "0.1.0"),
            role: nil)
        // Known but untoggled: still false (off by default).
        #expect(await store.allowsACT(catalogID) == false)
        await store.setAllowsACT(true, catalogID: catalogID)
        #expect(await store.allowsACT(catalogID) == true)
        // A new session (upsert) must not reset the user's choice.
        await store.upsertCatalog(
            catalogID: catalogID,
            info: KTPPPluginInfo(name: "MarkItDown", vendor: "kt", version: "0.2.0"),
            role: nil)
        #expect(await store.allowsACT(catalogID) == true)
        await store.setAllowsACT(false, catalogID: catalogID)
        #expect(await store.allowsACT(catalogID) == false)
    }

    @Test("catalogue merges same-name catalogs into the earliest, with aliases")
    func catalogueDedupe() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kt-cat-\(UUID().uuidString.prefix(8)).json")
        defer { try? FileManager.default.removeItem(at: file) }

        // What the pairing era left behind: one plugin re-paired on every app
        // relaunch, one catalog row per relaunch (legacy bare-array format).
        let ids = [UUID.v7(), UUID.v7(), UUID.v7()]
        let entries = ids.enumerated().map { index, id in
            KeepTalkingPluginCatalogueEntry(
                catalogID: id, name: "MarkItDown", vendor: "kt", version: "0.1.0",
                role: nil,
                kinds: [
                    KTPPKindDeclaration(
                        kindName: "markitdown-convert", displayName: "Convert",
                        indexDescription: "", inputSchema: nil, scopeSchema: nil,
                        defaultScope: nil, subTools: nil, objects: nil,
                        capabilities: nil, remoteAuthorisable: nil,
                        blockingAuthorisation: nil)
                ],
                meters: [], manifestVersion: "0.1.0",
                pairedAt: Date(timeIntervalSince1970: Double(1000 + index)),
                lastSeenAt: Date(timeIntervalSince1970: Double(2000 + index)),
                allowsACT: index == 1 ? true : nil)
        }
        let data = try JSONEncoder().encode(entries)
        try data.write(to: file)

        let store = KeepTalkingPluginCatalogueStore(fileURL: file)
        // One survivor: the earliest pairing; the rest alias onto it.
        let survivors = await store.catalogues()
        #expect(survivors.count == 1)
        #expect(survivors.first?.catalogID == ids[0])
        for id in ids {
            #expect(await store.canonicalCatalogID(id) == ids[0])
        }
        // Consent granted on ANY duplicate survives the merge; a session
        // named "MarkItDown" resolves to the canonical row.
        #expect(await store.allowsACT(ids[0]) == true)
        #expect(await store.catalogID(forPluginName: "MarkItDown") == ids[0])
        #expect(await store.kind(catalogID: ids[0], kindName: "markitdown-convert") != nil)

        // The dedupe persists: a reload sees one entry and the alias map.
        await store.persistNow()
        let reloaded = KeepTalkingPluginCatalogueStore(fileURL: file)
        #expect(await reloaded.catalogues().count == 1)
        #expect(await reloaded.canonicalCatalogID(ids[2]) == ids[0])
    }

    @Test("a plugin never seen before gets a stable catalog id derived from its name")
    func derivedCatalogID() async {
        let store = KeepTalkingPluginCatalogueStore(fileURL: nil)
        let first = await store.catalogID(forPluginName: "computeruse")
        #expect(first == KeepTalkingPluginCatalogueStore.derivedCatalogID(pluginName: "computeruse"))
        #expect(first == KeepTalkingPluginCatalogueStore.derivedCatalogID(pluginName: "computeruse"))
        #expect(first != KeepTalkingPluginCatalogueStore.derivedCatalogID(pluginName: "browseruse"))
        // RFC 9562 version 8, variant 10.
        #expect(first.uuid.6 >> 4 == 0x8)
        #expect(first.uuid.8 >> 6 == 0b10)
    }

    @Test("a kind with no declared objects leaves acceptsFileInput false")
    func noObjectsNoFileInput() {
        let bundle = KeepTalkingPluginBundle(
            name: "Browser", catalogID: UUID(), kindName: "browser-task")
        let action = KeepTalkingAction(
            payload: .plugin(bundle), remoteAuthorisable: true, blockingAuthorisation: false)
        action.descriptor = KeepTalkingPluginHost.descriptor(for: bundle, kind: nil)
        #expect(!action.acceptsFileInput)

        // Output-only kinds accept no pushed input bytes either.
        let outputOnly = KTPPKindDeclaration(
            kindName: "generate",
            displayName: "Generate",
            indexDescription: "",
            inputSchema: nil,
            scopeSchema: nil,
            defaultScope: nil,
            subTools: nil,
            objects: [KTPPObjectDeclaration(name: "result", direction: "output")],
            capabilities: nil,
            remoteAuthorisable: nil,
            blockingAuthorisation: nil)
        action.descriptor = KeepTalkingPluginHost.descriptor(for: bundle, kind: outputOnly)
        #expect(!action.acceptsFileInput)
    }
}
