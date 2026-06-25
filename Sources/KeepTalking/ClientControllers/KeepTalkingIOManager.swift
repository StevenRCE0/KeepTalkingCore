import FluentKit
import Foundation

/// Owns KeepTalking's typed I/O envelope: staged inputs, writable output slots,
/// produced-resource delivery, transcript injection, and run cleanup.
final class KeepTalkingIOManager {
    unowned let client: KeepTalkingClient

    init(client: KeepTalkingClient) {
        self.client = client
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

    private func clipped(_ text: String, maxCharacters: Int) -> String {
        client.clipped(text, maxCharacters: maxCharacters)
    }

    private func tool(_ fields: [String: Any], _ toolCallID: String) -> AIMessage {
        client.toolMessage(payload: client.jsonString(fields), toolCallID: toolCallID)
    }

    private func toolResult(_ fields: [String: Any], _ toolCallID: String) -> [AIMessage] {
        [tool(fields, toolCallID)]
    }

    private func failedToolResult(
        _ error: String,
        functionName: String,
        toolCallID: String,
        fields: [String: Any] = [:]
    ) -> [AIMessage] {
        var payload = fields
        payload["ok"] = false
        payload["function_name"] = functionName
        payload["error"] = error
        return toolResult(payload, toolCallID)
    }

    private func readTool(
        functionName: String,
        mode: ReadMode,
        toolCallID: String,
        fields: [String: Any]
    ) -> AIMessage {
        var payload = fields
        payload["ok"] = true
        payload["function_name"] = functionName
        payload["mode"] = mode.rawValue
        return tool(payload, toolCallID)
    }

    private func readToolResult(
        functionName: String,
        mode: ReadMode,
        toolCallID: String,
        fields: [String: Any]
    ) -> [AIMessage] {
        [readTool(functionName: functionName, mode: mode, toolCallID: toolCallID, fields: fields)]
    }

    func nativeUserMessage(
        filename: String,
        mimeType: String,
        data: Data,
        leadText: String
    ) -> AIMessage {
        .user(
            parts: client.attachmentContentParts(
                filename: filename,
                mimeType: mimeType,
                data: data,
                leadText: leadText))
    }

    private func nativeAttachmentUserMessage(
        attachment: KeepTalkingContextAttachment,
        data: Data
    ) -> AIMessage {
        nativeUserMessage(
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            data: data,
            leadText: AIPromptPresets.attachmentInjectionLeadText(
                filename: attachment.filename,
                isImage: attachment.isImage))
    }

    func readContextResource(
        handleText: String,
        mode: ReadMode,
        maxCharacters: Int,
        toolCallID: String,
        functionName: String,
        context: KeepTalkingContext
    ) async throws -> [AIMessage] {
        guard let contextID = context.id,
            let handle = KTResourceManifest.resolveAgentHandle(handleText)?.id
        else {
            return failedToolResult(
                "invalid_attachment_id",
                functionName: functionName,
                toolCallID: toolCallID,
                fields: ["attachment_id": handleText])
        }

        guard let attachment = try await client.contextAttachment(handle, in: contextID)
        else {
            if let transcriptResult = try await voiceTranscriptReadResult(
                sessionID: handle,
                contextID: contextID,
                mode: mode,
                maxCharacters: maxCharacters,
                toolCallID: toolCallID,
                functionName: functionName
            ) {
                return transcriptResult
            }
            if let stagedResult = await stagedFileReadResult(
                handle: handle,
                mode: mode,
                maxCharacters: maxCharacters,
                toolCallID: toolCallID,
                functionName: functionName
            ) {
                return stagedResult
            }
            return failedToolResult(
                "attachment_not_found",
                functionName: functionName,
                toolCallID: toolCallID,
                fields: ["attachment_id": handleText])
        }

        let blobRecord = try await KeepTalkingBlobRecord.query(on: client.localStore.database)
            .filter(\.$id, .equal, attachment.blobID)
            .first()
        let aliasLookup = try await client.aliasLookup()
        let attachmentJSON = KTResourceManifest.contextAttachmentJSONObject(
            attachment,
            blobRecord: blobRecord,
            nodeAliasResolver: { aliasLookup.alias(for: .node($0)) }
        )

        switch mode {
            case .metadata:
                if let blobRecord {
                    blobRecord.lastAccessedAt = Date()
                    try await blobRecord.save(on: client.localStore.database)
                }
                return readToolResult(
                    functionName: functionName, mode: mode, toolCallID: toolCallID,
                    fields: [
                        "attachment": attachmentJSON
                    ])

            case .previewText:
                if let blobRecord {
                    blobRecord.lastAccessedAt = Date()
                    try await blobRecord.save(on: client.localStore.database)
                }
                let preview = KTResourceManifest.attachmentPreviewText(
                    from: attachment,
                    maxCharacters: maxCharacters,
                    clip: clipped)
                return readToolResult(
                    functionName: functionName, mode: mode, toolCallID: toolCallID,
                    fields: [
                        "attachment": attachmentJSON,
                        "has_preview": preview != nil,
                        "max_characters": maxCharacters,
                        "preview_text": preview ?? "",
                    ])

            case .native:
                guard let blobRecord else {
                    return failedToolResult(
                        "blob_unavailable",
                        functionName: functionName,
                        toolCallID: toolCallID,
                        fields: [
                            "mode": mode.rawValue,
                            "attachment": attachmentJSON,
                            "error_message": "Attachment bytes are not available locally yet.",
                        ])
                }
                guard blobRecord.availability == .ready else {
                    return failedToolResult(
                        "blob_not_ready",
                        functionName: functionName,
                        toolCallID: toolCallID,
                        fields: [
                            "mode": mode.rawValue,
                            "attachment": attachmentJSON,
                            "error_message":
                                "Attachment bytes exist in metadata but are not ready locally.",
                        ])
                }
                guard attachment.byteCount <= KeepTalkingClient.maxAINativeAttachmentBytes else {
                    return failedToolResult(
                        "attachment_too_large",
                        functionName: functionName,
                        toolCallID: toolCallID,
                        fields: [
                            "mode": mode.rawValue,
                            "attachment": attachmentJSON,
                            "error_message": "Attachment exceeds the native AI input budget.",
                            "max_native_bytes": KeepTalkingClient.maxAINativeAttachmentBytes,
                        ])
                }

                let data: Data
                do {
                    data = try client.blobStore.read(
                        relativePath: blobRecord.relativePath,
                        blobID: attachment.blobID
                    )
                } catch {
                    return failedToolResult(
                        "blob_read_failed",
                        functionName: functionName,
                        toolCallID: toolCallID,
                        fields: [
                            "mode": mode.rawValue,
                            "attachment": attachmentJSON,
                            "error_message": error.localizedDescription,
                        ])
                }

                let now = Date()
                blobRecord.lastAccessedAt = now
                blobRecord.aiLastNativeIncludeAt = now
                try await blobRecord.save(on: client.localStore.database)

                return [
                    readTool(
                        functionName: functionName, mode: mode, toolCallID: toolCallID,
                        fields: [
                            "attachment": attachmentJSON,
                            "native_injected": true,
                        ]),
                    nativeAttachmentUserMessage(
                        attachment: attachment,
                        data: data
                    ),
                ]
        }
    }

    private func voiceTranscriptReadResult(
        sessionID: UUID,
        contextID: UUID,
        mode: ReadMode,
        maxCharacters: Int,
        toolCallID: String,
        functionName: String
    ) async throws -> [AIMessage]? {
        let aliasLookup = try await client.aliasLookup()
        guard
            let summary = try await client.voiceTranscriptSessionSummaries(in: contextID)
                .first(where: { $0.sessionID == sessionID })
        else { return nil }

        let attachmentJSON = KTResourceManifest.voiceTranscriptVirtualAttachmentJSON(
            summary, aliasLookup: aliasLookup)

        switch mode {
            case .metadata:
                return readToolResult(
                    functionName: functionName, mode: mode, toolCallID: toolCallID,
                    fields: [
                        "attachment": attachmentJSON
                    ])

            case .previewText:
                let text =
                    (try await client.renderVoiceTranscript(
                        forSession: sessionID,
                        in: contextID,
                        aliasLookup: aliasLookup,
                        maxCharacters: maxCharacters
                    )) ?? ""
                return readToolResult(
                    functionName: functionName, mode: mode, toolCallID: toolCallID,
                    fields: [
                        "attachment": attachmentJSON,
                        "has_preview": !text.isEmpty,
                        "max_characters": maxCharacters,
                        "preview_text": text,
                    ])

            case .native:
                let full =
                    (try await client.renderVoiceTranscript(
                        forSession: sessionID,
                        in: contextID,
                        aliasLookup: aliasLookup,
                        maxCharacters: 24_000
                    )) ?? ""
                let lead =
                    "Voice call transcript you requested (session \(sessionID.uuidString.prefix(8))) — included below. Use it directly."
                return [
                    readTool(
                        functionName: functionName, mode: mode, toolCallID: toolCallID,
                        fields: [
                            "attachment": attachmentJSON,
                            "native_injected": true,
                        ]),
                    .user("\(lead)\n\n\(full)"),
                ]
        }
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
            let staged = await client.stagedFileStore.file(
                handle: handle, callerNodeID: client.config.node)
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

    private func stagedFileReadResult(
        handle: UUID,
        mode: ReadMode,
        maxCharacters: Int,
        toolCallID: String,
        functionName: String
    ) async -> [AIMessage]? {
        guard let staged = await stagedResource(handle: handle) else { return nil }

        switch mode {
            case .metadata:
                return readToolResult(
                    functionName: functionName, mode: mode, toolCallID: toolCallID,
                    fields: [
                        "resource": staged.manifestJSON
                    ])
            case .previewText:
                let data = (try? Data(contentsOf: staged.url)) ?? Data()
                let text =
                    String(data: data, encoding: .utf8)
                    .map { clipped($0, maxCharacters: maxCharacters) }
                    ?? "<binary file, \(staged.byteCount) bytes — use native mode>"
                return readToolResult(
                    functionName: functionName, mode: mode, toolCallID: toolCallID,
                    fields: [
                        "handle": staged.handleText,
                        "name": staged.filename,
                        "content": text,
                    ])
            case .native:
                guard let data = try? Data(contentsOf: staged.url) else { return nil }
                let leadText = AIPromptPresets.attachmentInjectionLeadText(
                    filename: staged.filename,
                    isImage: staged.mimeType.hasPrefix("image/"))
                return [
                    nativeUserMessage(
                        filename: staged.filename,
                        mimeType: staged.mimeType,
                        data: data,
                        leadText: leadText),
                    readTool(
                        functionName: functionName, mode: mode, toolCallID: toolCallID,
                        fields: [
                            "handle": staged.handleText,
                            "name": staged.filename,
                            "note": "file content attached as a user message",
                        ]),
                ]
        }
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
                        let staged = await client.stagedFileStore.stageLocalFile(
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
            await client.stagedFileStore.register(
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
    func prepareCallBinding(
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
                    let base = sanitizeFileComponent(handle.name) ?? "output-\(index + 1)"
                    let kind: KTResourceManifest.Kind =
                        handle.persistence == .attachment ? .attachment : .otb
                    let isCollection = handle.multiple
                    outputs.append(
                        KTCallBinding.BoundObject(
                            objectName: handle.name,
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

    private func sanitizeFileComponent(_ name: String) -> String? {
        let cleaned =
            name
            .components(separatedBy: .controlCharacters).joined()
            .components(separatedBy: .newlines).joined()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? nil : cleaned
    }

    struct PreparedSkillRun {
        let attachmentsDir: URL?
        let sandboxPolicy: KTSandboxPolicy?
        let manifest: KTResourceManifest?
        let workspaceDirectory: URL?
        let outputSlots: [KTCallBinding.BoundObject]

        fileprivate let stagedAttachments: KeepTalkingStagedAttachments?
        fileprivate let ownedInputDir: URL?
        fileprivate let workspaceThreadID: UUID?
        fileprivate let workspaceRunStarted: Bool
    }

    func prepareSkillRun(
        action: KeepTalkingAction,
        request: KeepTalkingActionCallRequest,
        grant: KeepTalkingActionScope
    ) async throws -> PreparedSkillRun {
        let staged = await client.stageContextAttachments(in: request.contextID)
        var attachmentsDir = staged?.directory
        var ownedInputDir: URL?
        var otbInputs: [(handle: UUID, url: URL)] = []

        if action.acceptsFileInput, request.call.inputHandles?.isEmpty == false {
            let dir: URL
            if let existing = attachmentsDir {
                dir = existing
            } else {
                dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent(
                        "kt-otb-skillin-\(request.id.uuidString.lowercased())",
                        isDirectory: true)
                ownedInputDir = dir
            }
            otbInputs = try await client.resolveStagedInputs(
                request.call, callerNodeID: request.callerNodeID, into: dir)
            attachmentsDir = dir
        }

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

        let binding = prepareCallBinding(
            action: action,
            call: request.call,
            attachments: (staged?.files ?? []).map {
                StagedInputResource(
                    id: $0.id,
                    path: URL(fileURLWithPath: $0.path),
                    displayName: $0.filename)
            },
            otbInputs: otbInputs,
            attachmentsDir: attachmentsDir,
            workspaceDir: workspaceDir)

        let policy = try await resolvePolicy(
            action: action,
            grant: grant,
            binding: binding,
            attachmentsDir: attachmentsDir,
            workspaceDir: &workspaceDir)

        let outputSlots = workspaceDir == nil ? [] : binding.outputs
        prepareOutputSlots(outputSlots)

        let manifest = buildManifest(
            binding: binding,
            outputSlots: outputSlots,
            attachmentsDir: attachmentsDir,
            attachmentsGranted: policy.attachmentsGranted)

        logPreparedSlots(outputSlots, actionID: request.call.action)

        return PreparedSkillRun(
            attachmentsDir: attachmentsDir,
            sandboxPolicy: policy.sandboxPolicy,
            manifest: manifest,
            workspaceDirectory: workspaceDir,
            outputSlots: outputSlots,
            stagedAttachments: staged,
            ownedInputDir: ownedInputDir,
            workspaceThreadID: workspaceThreadID,
            workspaceRunStarted: workspaceRunStarted)
    }

    func cleanup(_ run: PreparedSkillRun, consumedInputHandles: [UUID]?) {
        if run.workspaceRunStarted, let threadID = run.workspaceThreadID {
            Task { [weak client] in await client?.endThreadWorkspaceRun(threadID) }
        }
        run.stagedAttachments.map { client.cleanupStagedAttachments($0) }
        run.ownedInputDir.map { try? FileManager.default.removeItem(at: $0) }

        guard let handles = consumedInputHandles, !handles.isEmpty else { return }
        Task { [stagedFileStore = client.stagedFileStore] in
            for handle in handles {
                await stagedFileStore.discardIfConsumable(handle: handle)
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
