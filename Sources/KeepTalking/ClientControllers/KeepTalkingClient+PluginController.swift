//
//  KeepTalkingClient+PluginController.swift
//  KeepTalking
//
//  The Catalogue on a client: browsing the kinds connected plugins provide,
//  minting instances from them, and the ACT turn plugin calls run.
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
    static let textByteCap = KeepTalkingCompanionLink.maxActAttachmentBytes
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

    /// One bounded, tool-less ACT turn on THIS node's local connector — the
    /// AI seam behind `host.act.request`. Always the plugin host node's own
    /// provider/keys/model; remote callers contribute attribution only, and
    /// nothing here ever routes toward them (resources design doc §4.2).
    func performPluginACTTurn(
        _ request: KTPPActTurnRequest,
        boundTo call: KTPPActCallContext
    ) async throws -> KTPPActResult {
        let agent = try await resolveAgentConfiguration(
            .init(contextID: call.contextID, purpose: .pluginACT(callerNodeID: call.callerNodeID))
        )
        let connector = agent.act.connector
        let model = agent.act.model

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

        // Image attachments ride as their own user messages between the
        // system preamble and the task, mirroring the tool-result inlining
        // convention.
        let turn = try await AdHocCompletion(connector: connector, model: model).run(
            instruction: systemPrompt,
            task: request.task,
            leadingMessages: imageMessages,
            maxOutputTokens: request.maxOutputTokens,
            responseFormat: request.expects == "json" ? .jsonObject : nil
        )
        onLog?(
            "[plugin-act] catalog=\(call.catalogName) kind=\(call.kindName) "
                + "invocation=\(call.invocationID.prefix(8)) model=\(model) "
                + "chars=\(turn.text.count)")
        // Token counts aren't surfaced by AITurnResult yet; the host records
        // request counts regardless, token fields join when connectors do.
        return KTPPActResult(
            text: turn.text,
            thinking: turn.thinking,
            model: model,
            usage: nil
        )
    }

    func refreshPluginInstanceDescriptorIfStale(_ action: KeepTalkingAction) async {
        guard case .plugin(let bundle) = action.payload,
            let kind = await companionLink.catalogue.kind(
                catalogID: bundle.catalogID, kindName: bundle.kindName),
            Set((kind.objects ?? []).map { "\($0.name)|\($0.direction)" })
                != Set(
                    (action.descriptor?.objects ?? []).map {
                        "\($0.name ?? "")|\($0.direction.rawValue)"
                    })
                || KeepTalkingCompanionLink.descriptor(for: bundle, kind: kind).action?.description
                    != action.descriptor?.action?.description
        else { return }

        action.descriptor = KeepTalkingCompanionLink.descriptor(for: bundle, kind: kind)
        onLog?(
            "[plugin] healed stale instance descriptor "
                + "action=\(action.id?.uuidString.lowercased().prefix(8) ?? "?") "
                + "kind=\(bundle.kindName) objects=\(kind.objects?.count ?? 0)")
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
        await companionLink.catalogue.setAllowsACT(allowed, catalogID: catalogID)
    }

    public func pluginCatalogAllowsACT(_ catalogID: UUID) async -> Bool {
        await companionLink.catalogue.allowsACT(catalogID)
    }

    // MARK: Catalogue

    /// Known plugin catalogs and their declared kinds — persisted, so this
    /// answers even while every plugin is offline.
    public func pluginCatalogues() async -> [KeepTalkingPluginCatalogueEntry] {
        await companionLink.catalogue.catalogues()
    }

    /// Every kind a user could instantiate right now, for the Catalogue group
    /// in the action-creation UI. The direct analogue of
    /// `KeepTalkingClient.availablePrimitiveActions`.
    public func availablePluginKinds() async -> [KeepTalkingPluginActionKindSummary] {
        await companionLink.catalogue.availableKinds()
    }

    public func pluginKindSummary(
        catalogID: UUID, kindName: String
    ) async -> KeepTalkingPluginActionKindSummary? {
        await companionLink.catalogue.summary(catalogID: catalogID, kindName: kindName)
    }

    /// The choices `kind`'s plugin offers right now for one scope key (keys
    /// whose `scopeOptionsSpec(for:)` is live), for the instance form.
    /// `scope` is the form's current bag; `query` narrows long lists.
    public func pluginScopeOptions(
        for kind: KeepTalkingPluginActionKindSummary,
        key: String,
        scope: [String: Value] = [:],
        query: String? = nil
    ) async throws -> [KTPPScopeOption] {
        try await companionLink.scopeOptions(
            catalogID: kind.catalogID, kindName: kind.kindName, key: key, scope: scope, query: query,
            from: config.node)
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
        let bundle = try await companionLink.makeInstanceBundle(
            catalogID: catalogID, kindName: kindName, name: name, scope: scope)
        let summary = await companionLink.catalogue.summary(
            catalogID: catalogID, kindName: kindName)
        // Materialize the kind's declared file objects onto the instance
        // descriptor — the seam that flips `acceptsFileInput` and drives input
        // staging / output slots for this instance's calls (resources doc §3.3).
        let kind = await companionLink.catalogue.kind(
            catalogID: catalogID, kindName: kindName)
        return try await Self.registerAction(
            payload: .plugin(bundle),
            descriptor: KeepTalkingCompanionLink.descriptor(for: bundle, kind: kind),
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

    public func forgetPluginCatalogue(_ catalogID: UUID) async {
        await companionLink.catalogue.removeCatalog(catalogID)
    }

}

#endif
