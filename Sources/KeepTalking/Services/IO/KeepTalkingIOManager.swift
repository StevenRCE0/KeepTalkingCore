import FluentKit
import Foundation

/// Owns KeepTalking's typed I/O envelope: staged inputs, writable output slots,
/// produced-resource delivery, transcript injection, and run cleanup.
final class KeepTalkingIOManager {
    unowned let client: KeepTalkingClient
    private let staging: KeepTalkingStagingIOManager

    init(client: KeepTalkingClient) {
        self.client = client
        self.staging = KeepTalkingStagingIOManager(
            client: client,
            store: client.stagedFileStore)
    }

    struct DeliveredOutputs {
        var resources: [KTResourceManifest.AgentResource] = []
        var transfers: [KeepTalkingOneTimeBlobRef] = []
    }

    struct StagedInputResource: Sendable {
        let id: UUID
        let path: URL
        let displayName: String
    }

    enum ReadMode: String {
        case metadata
        case previewText = "preview_text"
        case native
    }

    struct StagedResource {
        let handleText: String
        let url: URL
        let filename: String
        let mimeType: String
        let byteCount: Int

        var manifestJSON: [String: Any] {
            [
                "handle": handleText,
                "kind": "otb",
                "direction": "read",
                "name": filename,
                "mime_type": mimeType,
                "byte_count": byteCount,
                "origin": "produced",
            ]
        }
    }

    func stagedResource(handle: UUID, filename: String? = nil) async -> StagedResource? {
        guard
            let staged = await staging.file(handle: handle, callerNodeID: client.config.node)
        else { return nil }
        let displayName = filename ?? staged.filename
        return StagedResource(
            handleText: KTResourceManifest.agentHandle(kind: .otb, id: handle),
            url: staged.url,
            filename: displayName,
            mimeType: MIMEType.inferredMIMEType(
                forFileAt: staged.url, filename: displayName),
            byteCount: staged.byteCount)
    }

    func deliverProducedOutputFiles(
        _ inputs: [KeepTalkingLocalAttachmentInput],
        persistence: KeepTalkingActionOutputHandle.Persistence,
        in contextID: UUID,
        to callerNodeID: UUID
    ) async -> DeliveredOutputs {
        switch persistence {
            case .attachment:
                let saved = (try? await client.summonContextAttachments(inputs, in: contextID)) ?? []
                return DeliveredOutputs(
                    resources: saved.map { KTResourceManifest.AgentResource.attachment($0) })

            case .otb where callerNodeID == client.config.node:
                var resources: [KTResourceManifest.AgentResource] = []
                for input in inputs {
                    let filename = input.filename ?? input.sourceURL.lastPathComponent
                    let mime = MIMEType.inferredMIMEType(
                        forFileAt: input.sourceURL,
                        filename: filename,
                        explicit: input.mimeType)
                    guard
                        let staged = await staging.stageLocalFile(
                            at: input.sourceURL, filename: filename,
                            callerNodeID: client.config.node)
                    else {
                        client.onLog?("[io/primitive-output] otb+local staging refused for \(filename)")
                        continue
                    }
                    resources.append(
                        .otb(
                            id: staged.handle,
                            name: filename,
                            mimeType: mime,
                            byteCount: staged.byteCount))
                }
                return DeliveredOutputs(resources: resources)

            case .otb:
                var transfers: [KeepTalkingOneTimeBlobRef] = []
                for input in inputs {
                    let filename = input.filename ?? input.sourceURL.lastPathComponent
                    let mime = MIMEType.inferredMIMEType(
                        forFileAt: input.sourceURL,
                        filename: filename,
                        explicit: input.mimeType)
                    if let ref = try? await client.sendOneTimeBlob(
                        fileURL: input.sourceURL,
                        filename: filename,
                        mimeType: mime,
                        to: callerNodeID)
                    {
                        transfers.append(ref)
                    }
                }
                return DeliveredOutputs(
                    resources: transfers.map(KTResourceManifest.AgentResource.otb),
                    transfers: transfers)
        }
    }

    func materializeProducedOTBOutputs(
        _ refs: [KeepTalkingOneTimeBlobRef],
        from senderNodeID: UUID
    ) async {
        for ref in refs {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent(
                    "kt-otb-out-\(ref.transferID.uuidString.lowercased())",
                    isDirectory: true)
            guard
                let url = try? await client.materializeOneTimeBlob(
                    ref, from: senderNodeID, into: dir)
            else {
                client.onLog?(
                    "[io/materialize] FAILED transfer=\(ref.transferID.uuidString.prefix(8))")
                continue
            }
            await staging.register(
                handle: ref.transferID,
                url: url,
                callerNodeID: client.config.node,
                filename: ref.filename,
                byteCount: ref.byteCount,
                consumeOnUse: false)
            client.onLog?(
                "[io/materialize] staged transfer=\(ref.transferID.uuidString.prefix(8)) "
                    + "name=\(ref.filename) for local read")
        }
    }

    #if os(macOS)
    static func prepareCallBinding(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall,
        attachments: [StagedInputResource],
        otbInputs: [(handle: UUID, url: URL)],
        attachmentsDir: URL?,
        workspaceDir: URL?
    ) -> KTCallBinding {
        let descriptor = action.descriptor
        let pureInputs = (descriptor?.objects ?? []).filter {
            $0.isFile && $0.direction == .input
        }
        let outputObjects = descriptor?.fileObjects(direction: .output) ?? []

        var inputs = attachments.map {
            KTCallBinding.BoundObject(
                objectName: nil,
                id: $0.id,
                kind: .attachment,
                path: $0.path,
                direction: .input,
                displayName: $0.displayName,
                isDirectory: false)
        }

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

        // Context-ATTACHMENT handles the caller explicitly passed via
        // `input_handles` bind to declared input objects too — a plugin handler
        // addresses its source by the declared objectName, and "the PDF already
        // attached to this context" is as legitimate an input as a kt_send_file
        // OTB. Binding follows inputHandles order onto the remaining unconsumed
        // declared inputs; attachments the caller did NOT name stay catch-all
        // (objectName nil), exactly as before.
        if let handles = call.inputHandles, !handles.isEmpty {
            for handle in handles {
                guard
                    let j = pureInputs.indices.first(where: {
                        !consumed.contains($0) && pureInputs[$0].name != nil
                    })
                else { break }
                if let index = inputs.firstIndex(where: {
                    $0.id == handle && $0.kind == .attachment && $0.objectName == nil
                }) {
                    inputs[index].objectName = pureInputs[j].name
                    consumed.insert(j)
                }
            }
        }

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
                // For Catalogue (.plugin) instances the kind's DECLARED output
                // objects are the handler's vocabulary: a caller may label its
                // requested output anything ("catalogue_markdown"), but the
                // slot must still answer to the declared objectName the plugin
                // code looks up. Caller labels keep driving the delivered
                // filename, persistence, and collection-ness; positional extras
                // beyond the declared set keep their caller names. Skills keep
                // the caller-label semantics unchanged (scripts are TOLD their
                // exact write variables per run).
                //
                // Binding is by NAME first, position only as a fallback among
                // the declared objects nothing has claimed yet. Pure position
                // was wrong the moment a caller asked for a subset or a
                // different order: requesting only the second declared output
                // labelled the slot with the FIRST object's name, so the
                // handler's lookup missed it and the slot harvested empty.
                var unclaimedDeclared: [String] = []
                if action.payload.bindsOutputsByDeclaredName {
                    unclaimedDeclared = outputObjects.compactMap(\.name)
                }
                for (index, handle) in callerHandles.enumerated() {
                    var objectName = handle.name
                    if !unclaimedDeclared.isEmpty {
                        if let exact = unclaimedDeclared.firstIndex(of: handle.name) {
                            objectName = unclaimedDeclared.remove(at: exact)
                        } else {
                            objectName = unclaimedDeclared.removeFirst()
                        }
                    }
                    let base = sanitizeFileComponent(handle.name) ?? "output-\(index + 1)"
                    let kind: KTResourceManifest.Kind =
                        handle.persistence == .attachment ? .attachment : .otb
                    let isCollection = handle.multiple
                    outputs.append(
                        KTCallBinding.BoundObject(
                            objectName: objectName,
                            id: handle.id,
                            kind: kind,
                            path: workspaceDir.appendingPathComponent(
                                uniqueFileName(base),
                                isDirectory: isCollection),
                            direction: .output,
                            displayName: handle.name,
                            isDirectory: isCollection))
                }
            } else {
                for (index, object) in outputObjects.enumerated() {
                    let base =
                        object.name.flatMap(sanitizeFileComponent)
                        ?? "output-\(index + 1)"
                    let direction: KeepTalkingResourceDirection =
                        object.direction == .inputOutput ? .inputOutput : .output
                    let fileName = uniqueFileName(base)
                    outputs.append(
                        KTCallBinding.BoundObject(
                            objectName: object.name,
                            id: UUID.v7(),
                            kind: .otb,
                            path: workspaceDir.appendingPathComponent(
                                fileName,
                                isDirectory: false),
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
                KTCallBinding.GrantedDirectory(url: workspaceDir, direction: .inputOutput)
        }

        return KTCallBinding(
            inputs: inputs,
            outputs: outputs,
            grantedDirectories: grantedDirectories)
    }

    func producedOutputFiles(
        from outputs: [KTCallBinding.BoundObject]
    ) -> [KeepTalkingLocalAttachmentInput] {
        outputs.flatMap(resolveOutputFiles).map {
            KeepTalkingLocalAttachmentInput(
                sourceURL: $0,
                filename: $0.lastPathComponent,
                mimeType: MIMEType.inferredMIMEType(
                    forFileAt: $0,
                    filename: $0.lastPathComponent))
        }
    }

    private func resolveOutputFiles(_ output: KTCallBinding.BoundObject) -> [URL] {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: output.path.path, isDirectory: &isDir)
        else { return [] }
        guard isDir.boolValue else { return [output.path] }
        let items =
            (try? fileManager.contentsOfDirectory(
                at: output.path,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])) ?? []
        return
            items
            .filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { $0.path < $1.path }
    }

    private static func sanitizeFileComponent(_ name: String) -> String? {
        let cleaned =
            name
            .components(separatedBy: .controlCharacters).joined()
            .components(separatedBy: .newlines).joined()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? nil : cleaned
    }

    struct PreparedActionRun {
        let attachmentsDir: URL?
        let sandboxPolicy: KTSandboxPolicy?
        let manifest: KTResourceManifest?
        let workspaceDirectory: URL?
        let outputSlots: [KTCallBinding.BoundObject]

        fileprivate let stagedInputs: KeepTalkingStagingIOManager.PreparedInputs
        fileprivate let workspaceThreadID: UUID?
        fileprivate let workspaceRunStarted: Bool
    }

    /// Stages a call's file inputs, allocates its workspace output slots, and
    /// builds the run manifest — the shared front half of every file-consuming
    /// executor. Skills additionally get a compiled sandbox policy; `.plugin`
    /// payloads skip policy resolution entirely (KT neither launches nor
    /// contains plugin processes — design doc §9; their manifest projects into
    /// the KTPP call frame instead of a subprocess environment).
    func prepareActionRun(
        action: KeepTalkingAction,
        request: KeepTalkingActionCallRequest,
        grant: KeepTalkingActionScope
    ) async throws -> PreparedActionRun {
        let stagedInputs = try await staging.prepareInputs(action: action, request: request)
        let attachmentsDir = stagedInputs.directory

        var workspaceThreadID: UUID?
        var workspaceDir: URL?
        var workspaceRunStarted = false
        workspaceThreadID =
            (try? await client.ensureContextMainThread(
                for: request.contextID))?.id
        if let threadID = workspaceThreadID {
            workspaceDir = try? await client.threadWorkspace(for: threadID)
            if workspaceDir != nil {
                await client.beginThreadWorkspaceRun(threadID)
                workspaceRunStarted = true
            }
        }

        let binding = Self.prepareCallBinding(
            action: action,
            call: request.call,
            attachments: stagedInputs.attachments,
            otbInputs: stagedInputs.otbInputs,
            attachmentsDir: attachmentsDir,
            workspaceDir: workspaceDir)

        let policy: (sandboxPolicy: KTSandboxPolicy?, attachmentsGranted: Bool)
        if action.payload.usesCompiledSandboxPolicy {
            policy = try await resolvePolicy(
                action: action,
                grant: grant,
                binding: binding,
                attachmentsDir: attachmentsDir,
                workspaceDir: &workspaceDir)
        } else {
            policy = (nil, attachmentsDir != nil)
        }

        let outputSlots = workspaceDir == nil ? [] : binding.outputs
        prepareOutputSlots(outputSlots)

        // Plugin calls carry ONLY intentional reads: resources bound to a
        // declared object or explicitly named in `input_handles`. Skills keep
        // the catch-all (their scripts browse $KT_ATTACHMENTS by design), but a
        // plugin handler addresses declared names — unnamed context attachments
        // are noise that widens disclosure AND poisons lookups: one call's
        // harvested output attachment would make the next call's sole-input
        // fallback ambiguous (the exact live failure this rule came from).
        var manifestBinding = binding
        if action.payload.limitsManifestInputsToDeclared {
            let explicitlyNamed = Set(request.call.inputHandles ?? [])
            manifestBinding.inputs = binding.inputs.filter {
                $0.objectName != nil || explicitlyNamed.contains($0.id)
            }
        }

        let manifest = buildManifest(
            binding: manifestBinding,
            outputSlots: outputSlots,
            attachmentsDir: attachmentsDir,
            attachmentsGranted: policy.attachmentsGranted)

        logPreparedSlots(outputSlots, actionID: request.call.action)

        return PreparedActionRun(
            attachmentsDir: attachmentsDir,
            sandboxPolicy: policy.sandboxPolicy,
            manifest: manifest,
            workspaceDirectory: workspaceDir,
            outputSlots: outputSlots,
            stagedInputs: stagedInputs,
            workspaceThreadID: workspaceThreadID,
            workspaceRunStarted: workspaceRunStarted)
    }

    func cleanup(_ run: PreparedActionRun, consumedInputHandles: [UUID]?) {
        if run.workspaceRunStarted, let threadID = run.workspaceThreadID {
            Task { [weak client] in await client?.endThreadWorkspaceRun(threadID) }
        }
        staging.cleanup(run.stagedInputs)

        guard let handles = consumedInputHandles, !handles.isEmpty else { return }
        Task { [store = staging.store, handles] in
            for handle in handles {
                await store.discardIfConsumable(handle: handle)
            }
        }
    }

    func deliverOutputs(
        _ outputSlots: [KTCallBinding.BoundObject],
        contextID: UUID,
        callerNodeID: UUID,
        actionID: UUID
    ) async -> DeliveredOutputs {
        guard !outputSlots.isEmpty else { return DeliveredOutputs() }

        var delivered = DeliveredOutputs()
        let attachmentFiles = producedOutputFiles(
            from: outputSlots.filter { $0.kind == .attachment })
        if !attachmentFiles.isEmpty {
            let result = await deliverProducedOutputFiles(
                attachmentFiles, persistence: .attachment,
                in: contextID, to: callerNodeID)
            delivered.resources.append(contentsOf: result.resources)
        }

        let otbFiles = producedOutputFiles(
            from: outputSlots.filter { $0.kind != .attachment })
        if !otbFiles.isEmpty {
            let result = await deliverProducedOutputFiles(
                otbFiles, persistence: .otb,
                in: contextID, to: callerNodeID)
            delivered.resources.append(contentsOf: result.resources)
            delivered.transfers.append(contentsOf: result.transfers)
        }

        client.onLog?(
            "[io/outputs] action=\(actionID.uuidString.prefix(8)) "
                + "attachment=\(attachmentFiles.count) otb=\(otbFiles.count) "
                + "caller=\(callerNodeID.uuidString.prefix(8))")
        return delivered
    }

    private func resolvePolicy(
        action: KeepTalkingAction,
        grant: KeepTalkingActionScope,
        binding: KTCallBinding,
        attachmentsDir: URL?,
        workspaceDir: inout URL?
    ) async throws -> (sandboxPolicy: KTSandboxPolicy?, attachmentsGranted: Bool) {
        let extraDirectories = Dictionary(
            uniqueKeysWithValues: binding.grantedDirectories.map {
                ($0.key, (url: $0.value.url, direction: $0.value.direction))
            })

        guard !extraDirectories.isEmpty else {
            return (
                try? await client.scopeManager.resolvedPolicy(for: action, callerScope: grant),
                false
            )
        }

        if let granted = try? await client.scopeManager.resolvedPolicy(
            for: action,
            extraDirectories: extraDirectories,
            callerScope: grant)
        {
            return (granted, attachmentsDir != nil)
        }

        let fallback = try? await client.scopeManager.resolvedPolicy(
            for: action, callerScope: grant)
        let attachmentsGranted = attachmentsDir != nil && fallback == nil
        if fallback != nil { workspaceDir = nil }
        return (fallback, attachmentsGranted)
    }

    private func buildManifest(
        binding: KTCallBinding,
        outputSlots: [KTCallBinding.BoundObject],
        attachmentsDir: URL?,
        attachmentsGranted: Bool
    ) -> KTResourceManifest? {
        var candidates: [KTResourceManifest.Candidate] = []
        if attachmentsGranted {
            candidates.append(contentsOf: binding.inputs.map(\.manifestCandidate))
        }
        candidates.append(contentsOf: outputSlots.map(\.manifestCandidate))
        guard !candidates.isEmpty else { return nil }
        return KTResourceManifest.build(
            grantedCandidates: candidates,
            umbrellaAttachmentsDir: attachmentsGranted ? attachmentsDir : nil)
    }

    private func prepareOutputSlots(_ outputSlots: [KTCallBinding.BoundObject]) {
        for output in outputSlots {
            try? FileManager.default.removeItem(at: output.path)
            if output.isDirectory {
                try? FileManager.default.createDirectory(
                    at: output.path, withIntermediateDirectories: true)
            }
        }
    }

    private func logPreparedSlots(_ outputSlots: [KTCallBinding.BoundObject], actionID: UUID) {
        guard !outputSlots.isEmpty else { return }
        client.onLog?(
            "[io/slots] action=\(actionID.uuidString.prefix(8)) "
                + "prepared=\(outputSlots.count) "
                + "attachment=\(outputSlots.filter { $0.kind == .attachment }.count) "
                + "otb=\(outputSlots.filter { $0.kind == .otb }.count) "
                + "collections=\(outputSlots.filter { $0.isDirectory }.count)")
    }
    #endif
}
