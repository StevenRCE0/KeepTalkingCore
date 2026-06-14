import Foundation
import MCP

extension KeepTalkingClient {

    /// A resolved file input the caller has already staged locally for this run.
    public struct StagedInputResource: Sendable {
        public let id: UUID
        public let path: URL
        public let displayName: String

        public init(id: UUID, path: URL, displayName: String) {
            self.id = id
            self.path = path
            self.displayName = displayName
        }
    }

    /// Binds an action's declared SVO objects to the concrete resources resolved
    /// for ONE run — the bridge from the declared "O" (`KeepTalkingActionObject`)
    /// to the resolved `KTResourceManifest`. Pure, deterministic, provider-only.
    ///
    /// REGRESSION INVARIANT: when the descriptor declares no file objects
    /// (`descriptor.objects` nil/empty — every skill today), every input keeps a
    /// `nil` objectName, so the manifest falls back to `KT_ATTACHMENT_<H8>` /
    /// `KT_OTB_<H8>` exactly as before, and no output slots are allocated. The
    /// declared-object machinery only engages once an action opts in.
    ///
    /// - Parameters:
    ///   - attachments: Context attachments staged read-only into `$KT_ATTACHMENTS`
    ///     — always catch-all inputs (never bound to a declared object).
    ///   - otbInputs: One-time-blob file inputs the caller relayed, keyed by the
    ///     handle the call referenced; these bind to declared `.input` objects.
    ///   - attachmentsDir: The umbrella staging dir, granted read-only.
    ///   - workspaceDir: The thread workspace, granted read-write — where `.output`
    ///     slots are allocated. When `nil`, no outputs can be produced.
    func prepareCallBinding(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall,
        attachments: [StagedInputResource],
        otbInputs: [(handle: UUID, url: URL)],
        attachmentsDir: URL?,
        workspaceDir: URL?
    ) -> KTCallBinding {
        let descriptor = action.descriptor
        // Pure-input file objects bind to relayed OTB inputs. `.inputOutput`
        // objects are handled as writable output slots below (one path, not two).
        let pureInputs = (descriptor?.objects ?? []).filter {
            $0.isFile && $0.direction == .input
        }
        let outputObjects = descriptor?.fileObjects(direction: .output) ?? []

        var inputs: [KTCallBinding.BoundObject] = []

        // Context attachments — catch-all, never bound to a declared object.
        for attachment in attachments {
            inputs.append(
                KTCallBinding.BoundObject(
                    objectName: nil,
                    id: attachment.id,
                    kind: .attachment,
                    path: attachment.path,
                    direction: .input,
                    displayName: attachment.displayName,
                    isDirectory: false))
        }

        // OTB inputs → declared `.input` objects. Pass 1: explicit argument match
        // (the call argument named after the object references this handle).
        // Pass 2: positional fill of any still-unbound declared input, in order.
        var boundName: [String?] = Array(repeating: nil, count: otbInputs.count)
        var consumed = Set<Int>()
        for (i, input) in otbInputs.enumerated() {
            let handle = input.handle.uuidString.lowercased()
            for j in pureInputs.indices where !consumed.contains(j) {
                guard let name = pureInputs[j].name else { continue }
                if call.arguments[name]?.stringValue?.lowercased() == handle {
                    boundName[i] = name
                    consumed.insert(j)
                    break
                }
            }
        }
        for i in otbInputs.indices where boundName[i] == nil {
            if let j = pureInputs.indices.first(where: {
                !consumed.contains($0) && pureInputs[$0].name != nil
            }) {
                boundName[i] = pureInputs[j].name
                consumed.insert(j)
            }
        }
        for (i, input) in otbInputs.enumerated() {
            inputs.append(
                KTCallBinding.BoundObject(
                    objectName: boundName[i],
                    id: input.handle,
                    kind: .otb,
                    path: input.url,
                    direction: .input,
                    displayName: input.url.lastPathComponent,
                    isDirectory: false))
        }

        // Output write slots under the workspace. Prefer CALLER-allocated output
        // handles (the caller mints the id + picks persistence so it can track the
        // output and re-feed it as a later call's input — A→B chaining); fall back
        // to provider-minted slots from declared `.output` objects when the caller
        // declared none (back-compat). A harvested output is an OTB shipped
        // provider→caller ("an output is another OTB, inverted"); `persistence`
        // chooses the destination family (durable attachment vs ephemeral OTB).
        // NOTE: variable cardinality (`multiple` → a 0..N collection slot) is
        // handled in a later layer; here each handle allocates one file slot.
        var outputs: [KTCallBinding.BoundObject] = []
        if let workspaceDir {
            var usedNames = Set<String>()
            func uniqueFileName(_ base: String) -> String {
                var fileName = base
                var disambiguator = 2
                while usedNames.contains(fileName) {
                    fileName = "\(base)-\(disambiguator)"
                    disambiguator += 1
                }
                usedNames.insert(fileName)
                return fileName
            }

            if let callerHandles = call.outputHandles, !callerHandles.isEmpty {
                for (index, handle) in callerHandles.enumerated() {
                    let base =
                        Self.sanitizeFileComponent(handle.name) ?? "output-\(index + 1)"
                    let fileName = uniqueFileName(base)
                    let kind: KTResourceManifest.Kind =
                        handle.persistence == .attachment ? .attachment : .otb
                    // A `multiple` handle resolves to 0..N files: its slot is a
                    // DIRECTORY the skill writes into; harvest enumerates it. A
                    // single handle is one file slot. (isDirectory here marks the
                    // collection slot — distinct from a transferred file's nature.)
                    let isCollection = handle.multiple
                    outputs.append(
                        KTCallBinding.BoundObject(
                            objectName: handle.name,
                            id: handle.id,  // CALLER-allocated, round-trips with the output
                            kind: kind,
                            path: workspaceDir.appendingPathComponent(
                                fileName, isDirectory: isCollection),
                            direction: .output,
                            displayName: handle.name,
                            isDirectory: isCollection))
                }
            } else {
                for (index, object) in outputObjects.enumerated() {
                    let base =
                        object.name.flatMap(Self.sanitizeFileComponent)
                        ?? "output-\(index + 1)"
                    let fileName = uniqueFileName(base)
                    let direction: KeepTalkingResourceDirection =
                        object.direction == .inputOutput ? .inputOutput : .output
                    outputs.append(
                        KTCallBinding.BoundObject(
                            objectName: object.name,
                            id: UUID.v7(),
                            kind: .otb,
                            path: workspaceDir.appendingPathComponent(
                                fileName, isDirectory: false),
                            direction: direction,
                            displayName: object.name ?? fileName,
                            isDirectory: false))
                }
            }
        }

        var grantedDirectories: [String: KTCallBinding.GrantedDirectory] = [:]
        if let attachmentsDir {
            grantedDirectories["KT_ATTACHMENTS"] =
                KTCallBinding.GrantedDirectory(url: attachmentsDir, direction: .input)
        }
        if let workspaceDir {
            grantedDirectories["KT_WORKSPACE"] =
                KTCallBinding.GrantedDirectory(
                    url: workspaceDir, direction: .inputOutput)
        }

        return KTCallBinding(
            inputs: inputs, outputs: outputs, grantedDirectories: grantedDirectories)
    }

    /// Flattens declared `.output` slots to the concrete file(s) they produced, as
    /// `KeepTalkingLocalAttachmentInput`s ready for `deliverProducedOutputFiles`. A
    /// single-file slot contributes its file; a collection slot (a directory, from a
    /// `multiple` handle) contributes every regular file inside. A slot that produced
    /// nothing (e.g. its workspace grant was dropped) contributes nothing. This is
    /// the ONE place skill output slots become deliverable files — the per-Kind
    /// routing then lives solely in `deliverProducedOutputFiles`.
    func producedOutputFiles(
        from outputs: [KTCallBinding.BoundObject]
    ) -> [KeepTalkingLocalAttachmentInput] {
        outputs.flatMap { resolveOutputFiles($0) }.map {
            KeepTalkingLocalAttachmentInput(
                sourceURL: $0, filename: $0.lastPathComponent, mimeType: nil)
        }
    }

    /// Delivers produced output files per the caller's persistence switch, into the
    /// unified producedResources format — the SINGLE deliverer for every action
    /// output (skill slots AND primitive results), so an output is indistinguishable
    /// to the agent regardless of which action produced it.
    /// - `.attachment`: summon durable, synced context attachment(s) (any caller).
    /// - `.otb` to a REMOTE caller: ship private point-to-point (returns transfers).
    /// - `.otb` for a LOCAL caller: stage RE-FEEDABLE in the private store (never
    ///   broadcast) so the agent can read it AND chain it into a later action.
    func deliverProducedOutputFiles(
        _ inputs: [KeepTalkingLocalAttachmentInput],
        persistence: KeepTalkingActionOutputHandle.Persistence,
        in contextID: UUID,
        to callerNodeID: UUID
    ) async -> (
        resources: [KTResourceManifest.AgentResource],
        transfers: [KeepTalkingOneTimeBlobRef]
    ) {
        switch persistence {
            case .attachment:
                // Durable, shared: a broadcast (synced) attachment.
                let saved = (try? await summonContextAttachments(inputs, in: contextID)) ?? []
                return (saved.map { Self.attachmentResource($0) }, [])
            case .otb where callerNodeID == config.node:
                // PRIVATE local: register in the staged-file store — NEVER an
                // attachment, NEVER synced/broadcast. The agent reads it by handle
                // (kt_get_context_attachment resolves staged handles). The local
                // node is its own "caller" so it owns + can read the handle.
                var resources: [KTResourceManifest.AgentResource] = []
                for input in inputs {
                    let filename = input.filename ?? input.sourceURL.lastPathComponent
                    let mime =
                        input.mimeType
                        ?? MIMEType.preferredMIMEType(
                            forExtension: input.sourceURL.pathExtension)
                        ?? "application/octet-stream"
                    guard
                        let staged = await stagedFileStore.stageLocalFile(
                            at: input.sourceURL, filename: filename,
                            callerNodeID: config.node)
                    else {
                        onLog?("[io/primitive-output] otb+local staging refused for \(filename)")
                        continue
                    }
                    resources.append(
                        KTResourceManifest.AgentResource(
                            kind: .otb,
                            id: staged.handle,
                            direction: "read",
                            name: filename,
                            mimeType: mime,
                            byteCount: staged.byteCount,
                            origin: "produced"))
                }
                return (resources, [])
            case .otb:
                // PRIVATE remote: ship point-to-point; the caller materializes it.
                var refs: [KeepTalkingOneTimeBlobRef] = []
                for input in inputs {
                    let filename = input.filename ?? input.sourceURL.lastPathComponent
                    let mime =
                        input.mimeType
                        ?? MIMEType.preferredMIMEType(
                            forExtension: input.sourceURL.pathExtension)
                        ?? "application/octet-stream"
                    if let ref = try? await sendOneTimeBlob(
                        fileURL: input.sourceURL, filename: filename, mimeType: mime,
                        to: callerNodeID)
                    {
                        refs.append(ref)
                    }
                }
                return (producedOTBResources(refs), refs)
        }
    }

    /// Maps a context attachment to the unified agent-facing resource (origin
    /// "produced"). Shared by the skill-summon and primitive-output paths.
    static func attachmentResource(_ attachment: KeepTalkingContextAttachment)
        -> KTResourceManifest.AgentResource
    {
        KTResourceManifest.AgentResource(
            kind: .attachment,
            id: attachment.id ?? UUID(),
            direction: "read",
            name: attachment.filename,
            mimeType: attachment.mimeType,
            byteCount: attachment.byteCount,
            summary: attachment.metadata.textPreview ?? attachment.metadata.imageDescription,
            origin: "produced")
    }

    /// Materializes private `.otb` output transfers a remote action shipped back
    /// (e.g. a produced output / a remote ask-for-file's picked file) into THIS
    /// node's staged-file store, keyed by each transfer id — which is exactly the
    /// `handle` in the matching `produced_resources` entry. So the agent can read /
    /// auto-inject the produced file by handle AND re-feed it into a later action
    /// (A→B chaining), even though it was produced on another node and never
    /// broadcast. Registered re-feedable under config.node. Called by BOTH the
    /// continuation path and the direct remote-result path.
    func materializeProducedOTBOutputs(
        _ refs: [KeepTalkingOneTimeBlobRef], from senderNodeID: UUID
    ) async {
        for ref in refs {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent(
                    "kt-otb-out-\(ref.transferID.uuidString.lowercased())", isDirectory: true)
            guard
                let url = try? await materializeOneTimeBlob(
                    ref, from: senderNodeID, into: dir)
            else {
                onLog?(
                    "[io/materialize] FAILED transfer=\(ref.transferID.uuidString.prefix(8))")
                continue
            }
            await stagedFileStore.register(
                handle: ref.transferID, url: url, callerNodeID: config.node,
                filename: ref.filename, byteCount: ref.byteCount,
                // A remote-produced `.otb` materialized here is a re-feedable output
                // (it can flow into a later action call), not a consume-once relay.
                consumeOnUse: false)
            onLog?(
                "[io/materialize] staged transfer=\(ref.transferID.uuidString.prefix(8)) "
                    + "name=\(ref.filename) for local read")
        }
    }

    /// Maps harvested one-time-blob output refs into the unified agent-facing
    /// resource format (private `.otb` outputs the caller now holds).
    func producedOTBResources(_ refs: [KeepTalkingOneTimeBlobRef])
        -> [KTResourceManifest.AgentResource]
    {
        refs.map { ref in
            KTResourceManifest.AgentResource(
                kind: .otb,
                id: ref.transferID,
                direction: "read",
                name: ref.filename,
                mimeType: ref.mimeType,
                byteCount: ref.byteCount,
                origin: "produced")
        }
    }

    /// Resolves an output slot to the concrete file(s) it produced: a single-file
    /// slot → that file (when it exists); a collection slot (a directory, from a
    /// `multiple` output handle) → every regular file written into it, sorted for
    /// determinism. Empty when the run produced nothing at the slot.
    func resolveOutputFiles(_ output: KTCallBinding.BoundObject) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: output.path.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return [output.path] }
        let items =
            (try? fm.contentsOfDirectory(
                at: output.path,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])) ?? []
        return
            items
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
    }

    /// Folds a declared object name into a safe single path component: control
    /// chars and newlines stripped, path separators neutralised, `.`/`..` rejected.
    /// Returns `nil` when nothing usable survives (caller falls back to a generic
    /// slot name) — a declared name can never escape the workspace dir.
    static func sanitizeFileComponent(_ name: String) -> String? {
        let cleaned =
            name
            .components(separatedBy: .controlCharacters).joined()
            .components(separatedBy: .newlines).joined()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return nil }
        return cleaned
    }
}
