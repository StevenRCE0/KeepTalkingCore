//
//  KeepTalkingClient+PluginController.swift
//  KeepTalking
//
//  Public surface for the Catalogue: enabling the plugin host, browsing the
//  kinds paired plugins provide, and minting action instances from them —
//  the plugin analogue of the primitive creation flow.
//

#if os(macOS)

import FluentKit
import Foundation
import MCP

/// Renders one `host.act` attachment into transcript form (resources design
/// doc §7.1 resolution): text rides verbatim (trimmed at the cap — a model
/// gains nothing from a megabyte tail), images become inline image parts
/// (downscaled, embedded base64 data URLs), and other binary embeds as a
/// trimmed base64 block. Nothing fails the turn over size or encoding —
/// trimming beats erroring.
enum KTPPActAttachmentRendering {

    /// Text/base64 payload cap (bytes of source content).
    static let textByteCap = KeepTalkingPluginHost.maxActAttachmentBytes
    /// Raw-byte cap for base64-embedded binary (base64 inflates 4/3).
    static let binaryByteCap = 64 * 1024
    /// Post-downscale ceiling for an inlined image; beyond it the image
    /// degrades to a note rather than a prompt-crushing data URL.
    static let imageByteCap = 5 * 1024 * 1024

    enum Rendered {
        /// A block appended to the system prompt's resources section.
        case textBlock(String)
        /// A lead line + image part carried as its own user message.
        case imageMessage(lead: String, part: AIMessage.Part)
    }

    static func render(handle: String, name: String, path: URL) -> Rendered {
        let header = "--- resource \(handle) \"\(name)\""
        guard let data = try? Data(contentsOf: path) else {
            return .textBlock("\(header) --- (unreadable; content unavailable)")
        }
        let mimeType = MIMEType.inferredMIMEType(forFileAt: path, filename: name)

        if mimeType.hasPrefix("image/") {
            if let inlined = KeepTalkingClient.inlinedImagePart(
                mimeType: mimeType, data: data, byteCap: imageByteCap)
            {
                return .imageMessage(
                    lead: "Resource \(handle) \"\(name)\" (\(inlined.mimeType)):",
                    part: inlined.part)
            }
            return .textBlock(
                "\(header) --- (image of \(data.count) bytes, too large to inline)")
        }

        if let text = String(data: data, encoding: .utf8) {
            if data.count <= textByteCap {
                return .textBlock("\(header) ---\n\(text)")
            }
            let trimmed = String(decoding: data.prefix(textByteCap), as: UTF8.self)
            return .textBlock(
                "\(header) (first \(textByteCap) of \(data.count) bytes; truncated) ---\n"
                    + trimmed)
        }

        // Binary, non-image: a trimmed base64 embed. Trim the DATA before
        // encoding so the base64 stays decodable.
        let slice = data.prefix(binaryByteCap)
        let suffix =
            data.count > binaryByteCap
            ? " (first \(binaryByteCap) of \(data.count) bytes; truncated)" : ""
        return .textBlock(
            "\(header) (\(mimeType), base64\(suffix)) ---\n\(slice.base64EncodedString())")
    }
}

extension KeepTalkingClient {

    // MARK: Host lifecycle

    /// Starts the KTPP listener. Off by default: a node that never uses
    /// plugins never opens a socket. Also wires the ACT seam: the actor gates
    /// (call binding, consent, budget); this client supplies the model turn.
    public func enablePluginHost() async throws {
        await pluginHost.setACTHandler { [weak self] request, callContext in
            guard let self else {
                throw KTPPHostError.sessionUnavailable(callContext.catalogID)
            }
            return try await self.performPluginACTTurn(request, boundTo: callContext)
        }
        try await pluginHost.start()
    }

    /// One bounded, tool-less ACT turn on THIS node's local connector — the
    /// AI seam behind `host.act.request`. Always the plugin host node's own
    /// provider/keys/model; remote callers contribute attribution only, and
    /// nothing here ever routes toward them (resources design doc §4.2).
    func performPluginACTTurn(
        _ request: KTPPActTurnRequest,
        boundTo call: KTPPActCallContext
    ) async throws -> KTPPActResult {
        let actResolved = try await resolveACTConnector()
        let mainResolved = try await resolveAIConnector()
        guard let connector = actResolved ?? mainResolved else {
            throw KeepTalkingClientError.aiNotConfigured
        }
        let model = openAIModel ?? "gpt-5-codex"

        // Render requested attachments (§7.1): text verbatim (trimmed at the
        // cap), images as inline parts, other binary as trimmed base64.
        // Nothing fails the turn over size or encoding.
        var attachmentBlocks: [String] = []
        var imageMessages: [AIMessage] = []
        for attachment in request.attachments {
            switch KTPPActAttachmentRendering.render(
                handle: attachment.handle, name: attachment.name, path: attachment.path)
            {
                case .textBlock(let block):
                    attachmentBlocks.append(block)
                case .imageMessage(let lead, let part):
                    imageMessages.append(.user(parts: [.text(lead), part]))
            }
        }

        // Plugin-flavored ACT preamble: factual, no speculation, and the same
        // privacy posture as the kt_run_action ACT agent — the model's output
        // returns to a plugin process, so ambient host details stay out.
        var systemPrompt = """
            You are the ACT (Action-Calling-Turn) agent of the KeepTalking platform, \
            performing one bounded assist for a plugin that is executing a user-authorized \
            action call.

            Plugin: \(call.catalogName)
            Action kind: \(call.kindName)

            Complete the task below directly and concisely. Be factual; do not speculate, \
            do not ask questions, do not address anyone — your entire reply is consumed \
            programmatically by the plugin.

            Privacy and confidentiality: do not disclose, summarize, or infer the host \
            environment — local machine or system state, filesystem paths, connected \
            devices or nodes, credentials or configuration, or other ambient context. \
            Work only from the task and the resource content explicitly provided below.
            """
        if let extra = request.system?.trimmingCharacters(in: .whitespacesAndNewlines),
            !extra.isEmpty
        {
            systemPrompt += "\n\n\(extra)"
        }
        if !attachmentBlocks.isEmpty {
            systemPrompt += "\n\nProvided resources:\n\(attachmentBlocks.joined(separator: "\n\n"))"
        }

        let configuration = AITurnConfiguration(
            maxOutputTokens: request.maxOutputTokens,
            responseFormat: request.expects == "json" ? .jsonObject : nil
        )
        // Image attachments ride as their own user messages between the
        // system preamble and the task, mirroring the tool-result inlining
        // convention.
        let turn = try await connector.completeTurn(
            messages: [.system(systemPrompt)] + imageMessages + [.user(request.task)],
            tools: [],
            model: model,
            toolChoice: nil,
            stage: .execution,
            configuration: configuration,
            toolExecutor: nil
        )
        onLog?(
            "[plugin-act] catalog=\(call.catalogName) kind=\(call.kindName) "
                + "invocation=\(call.invocationID.prefix(8)) model=\(model) "
                + "chars=\((turn.assistantText ?? "").count)")
        // Token counts aren't surfaced by AITurnResult yet; the host records
        // request counts regardless, token fields join when connectors do.
        return KTPPActResult(
            text: turn.assistantText ?? "",
            thinking: turn.thinking,
            model: model,
            usage: nil
        )
    }

    /// Heals a Catalogue instance left behind by host evolution, at dispatch
    /// time, in two ways:
    /// 1. **Catalog aliasing** — an instance minted against a pairing that was
    ///    later deduped away (the re-pair-per-relaunch era) re-targets the
    ///    canonical catalog, so its calls reach the live session again.
    /// 2. **Descriptor staleness** — an instance minted before kind
    ///    declarations carried `objects` (pre-v1.1) re-materializes its
    ///    descriptor from the CURRENT declaration; without that,
    ///    `acceptsFileInput` stays false and no staged resource ever binds to
    ///    the declared names the plugin handler looks up.
    /// The minimal arm of the base doc's §12.1 kind-evolution story.
    func refreshPluginInstanceDescriptorIfStale(_ action: KeepTalkingAction) async {
        guard case .plugin(var bundle) = action.payload else { return }
        var mutated = false

        let canonical = await pluginHost.catalogue.canonicalCatalogID(bundle.catalogID)
        if canonical != bundle.catalogID {
            onLog?(
                "[plugin] healing instance catalog "
                    + "\(bundle.catalogID.uuidString.lowercased().prefix(8)) → "
                    + "\(canonical.uuidString.lowercased().prefix(8)) "
                    + "action=\(action.id?.uuidString.lowercased().prefix(8) ?? "?")")
            bundle.catalogID = canonical
            action.payload = .plugin(bundle)
            mutated = true
        }

        if action.descriptor?.objects?.isEmpty != false,
            let kind = await pluginHost.catalogue.kind(
                catalogID: bundle.catalogID, kindName: bundle.kindName),
            kind.objects?.isEmpty == false
        {
            action.descriptor = KeepTalkingPluginHost.descriptor(for: bundle, kind: kind)
            onLog?(
                "[plugin] healed stale instance descriptor "
                    + "action=\(action.id?.uuidString.lowercased().prefix(8) ?? "?") "
                    + "kind=\(bundle.kindName) objects=\(kind.objects?.count ?? 0)")
            mutated = true
        }

        guard mutated else { return }
        do {
            try await action.save(on: localStore.database)
        } catch {
            onLog?(
                "[plugin] instance heal failed to persist: \(error.localizedDescription)")
        }
    }

    /// Per-catalog ACT consent: may this catalog's plugins use the node's AI
    /// provider while executing calls? OFF until the user flips it.
    public func setPluginCatalogACTConsent(_ allowed: Bool, catalogID: UUID) async {
        await pluginHost.catalogue.setAllowsACT(allowed, catalogID: catalogID)
    }

    public func pluginCatalogAllowsACT(_ catalogID: UUID) async -> Bool {
        await pluginHost.catalogue.allowsACT(catalogID)
    }

    public func disablePluginHost() async {
        await pluginHost.stop()
    }

    public func setPluginPairingApprovalHandler(
        _ handler: @escaping @Sendable (KTPPPluginInfo, String) async -> Bool
    ) async {
        await pluginHost.setPairingApprovalHandler(handler)
    }

    public func setPluginEventHandler(
        _ handler: (@Sendable (KTPPHostEvent) -> Void)?
    ) async {
        await pluginHost.setEventHandler(handler)
    }

    // MARK: Catalogue

    /// Paired plugin catalogs and their declared kinds — persisted, so this
    /// answers even while every plugin is offline.
    public func pluginCatalogues() async -> [KeepTalkingPluginCatalogueEntry] {
        await pluginHost.catalogue.catalogues()
    }

    /// Every kind a user could instantiate right now, for the Catalogue group
    /// in the action-creation UI. The direct analogue of
    /// `KeepTalkingClient.availablePrimitiveActions`.
    public func availablePluginKinds() async -> [KeepTalkingPluginActionKindSummary] {
        await pluginHost.catalogue.availableKinds()
    }

    public func pluginKindSummary(
        catalogID: UUID, kindName: String
    ) async -> KeepTalkingPluginActionKindSummary? {
        await pluginHost.catalogue.summary(catalogID: catalogID, kindName: kindName)
    }

    // MARK: Instantiation

    /// Mints a persistent action instance from a Catalogue kind and registers
    /// it on this node — the Catalogue equivalent of creating a primitive
    /// action. The instance is inert until granted, exactly like every other
    /// newly created action.
    @discardableResult
    public func instantiatePluginAction(
        catalogID: UUID,
        kindName: String,
        name: String? = nil,
        scope: [String: Value]? = nil,
        node: KeepTalkingNode
    ) async throws -> KeepTalkingAction {
        let bundle = try await pluginHost.makeInstanceBundle(
            catalogID: catalogID, kindName: kindName, name: name, scope: scope)
        let summary = await pluginHost.catalogue.summary(
            catalogID: catalogID, kindName: kindName)
        // Materialize the kind's declared file objects onto the instance
        // descriptor — the seam that flips `acceptsFileInput` and drives input
        // staging / output slots for this instance's calls (resources doc §3.3).
        let kind = await pluginHost.catalogue.kind(
            catalogID: catalogID, kindName: kindName)
        return try await Self.registerAction(
            payload: .plugin(bundle),
            descriptor: KeepTalkingPluginHost.descriptor(for: bundle, kind: kind),
            remoteAuthorisable: summary?.remoteAuthorisable ?? true,
            blockingAuthorisation: bundle.blockingAuthorisation,
            node: node,
            on: localStore.database
        )
    }

    /// Updates the scope bag of an existing Catalogue instance. Rewriting the
    /// bag changes what future calls bind into their signed authorization, so
    /// past receipts stay attributable to the boundary that was in force.
    public func updatePluginActionScope(
        actionID: UUID,
        scope: [String: Value]?
    ) async throws {
        guard
            let action = try await KeepTalkingAction.find(
                actionID, on: localStore.database)
        else { throw KeepTalkingClientError.missingAction }
        guard case .plugin(var bundle) = action.payload else {
            throw KTPPHostError.protocolViolation("action is not a Catalogue instance")
        }
        bundle.scope = scope
        action.payload = .plugin(bundle)
        try await action.save(on: localStore.database)
    }

    /// Removes a Catalogue instance and its grants. There is no executor to
    /// unregister — the plugin process is untouched and keeps serving its other
    /// instances.
    public func removePluginAction(actionID: UUID) async throws {
        let node = try await getCurrentNodeInstance()
        try await Self.removeMCPAction(
            actionID: actionID,
            node: node,
            on: localStore.database,
            callbackForUnregisteringAction: nil
        )
        await invalidateActionToolCatalog(
            reason: "remove_plugin_action action=\(actionID.uuidString.lowercased())"
        )
        await broadcastLocalNodeState(
            reason: "remove_plugin_action action=\(actionID.uuidString.lowercased())"
        )
    }

    /// Forgets a paired plugin catalog and its kinds. Instances already minted
    /// from those kinds are NOT deleted — they are separate rows the user
    /// created, so removing them stays an explicit, separate decision.
    public func forgetPluginCatalogue(_ catalogID: UUID) async {
        await pluginHost.catalogue.removeCatalog(catalogID)
    }

    /// Bridges plugin-initiated proposals (`host.action.create`) to a
    /// confirmation UI. The closure receives the proposal and returns the
    /// created action id, or nil when the user declines.
    public func setPluginActionProposalHandler(
        _ handler: (@Sendable (KeepTalkingPluginActionProposal) async -> UUID?)?
    ) async {
        await pluginHost.setActionProposalHandler(handler)
    }
}

#endif
