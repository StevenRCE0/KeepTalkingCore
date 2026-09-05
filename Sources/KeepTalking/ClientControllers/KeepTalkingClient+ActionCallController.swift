import FluentKit
import Foundation
import MCP

extension KeepTalkingClient {
    /// How long a remote action-call result waits silently before it switches
    /// to patient liveness-polling. After this it waits indefinitely while the
    /// target node stays online (see `waitForActionCallResult`).
    private static let actionCallResultGraceSeconds: TimeInterval = 10
    /// Liveness poll cadence once a result wait exceeds its grace period.
    private static let actionCallResultPollSeconds: TimeInterval = 5
    private static let actionCallAckTimeoutSeconds: TimeInterval = 4
    private static let actionCallAckRetryLimit = 2
    private static let actionCallDeliveryCacheLimit = 32
    private static let completedIncomingActionCallCacheLimit = 32

    public func deliveryNodeID(forRemoteOwnerNodeID ownerNodeID: UUID) async throws
        -> UUID
    {
        if ownerNodeID == config.node {
            return ownerNodeID
        }
        return try await Self.deliveryNodeID(
            forRemoteOwnerNodeID: ownerNodeID,
            on: localStore.database
        )
    }

    public func deliveryNodeID(for action: KeepTalkingAction) async throws -> UUID? {
        guard let ownerNodeID = action.$node.id else {
            return nil
        }
        return try await deliveryNodeID(forRemoteOwnerNodeID: ownerNodeID)
    }

    public func isActionReachable(_ action: KeepTalkingAction) async -> Bool {
        guard let deliveryNodeID = try? await deliveryNodeID(for: action) else {
            return false
        }
        if deliveryNodeID == config.node {
            return true
        }
        return isNodeOnline(deliveryNodeID)
    }

    /// Live MCP runtime health for a locally-owned action. Use this in the
    /// app's action settings panel to show "Connected", "Connecting…",
    /// "Failed: <reason>", "Disabled", etc. — the same signal that
    /// node-status broadcasts encode in `KeepTalkingAdvertisedAction.availability`.
    ///
    /// Non-MCP payloads always return `.notRegistered` since MCPManager only
    /// tracks MCP-backed actions; callers should fall back to `disabled` and
    /// reachability for those.
    public func mcpHealth(for actionID: UUID) async -> MCPActionHealth {
        await mcpManager.actionHealth(actionID: actionID)
    }

    func enqueueIncomingActionCallRequest(
        _ request: KeepTalkingActionCallRequest
    ) {
        guard request.targetNodeID == config.node else {
            return
        }
        Task { [weak self] in
            do {
                try await self?.handleIncomingActionCallRequest(request)
            } catch {
                self?.onLog?(
                    "[action-call/request] failed request=\(request.id.uuidString.lowercased()) action=\(request.call.action.uuidString.lowercased()) error=\(error.localizedDescription)"
                )
            }
        }
    }

    private static func deliveryNodeID(
        forRemoteOwnerNodeID ownerNodeID: UUID,
        on database: any Database,
        visited: Set<UUID> = []
    ) async throws -> UUID {
        return ownerNodeID
        // TODO: Very interesting walking logic, leave it for another day...Not hopping now.
        //        if visited.contains(ownerNodeID) {
        //            return ownerNodeID
        //        }
        //
        //        let ownerRelations = try await KeepTalkingNodeRelation.query(on: database)
        //            .filter(\.$to.$id, .equal, ownerNodeID)
        //            .all()
        //            .filter { $0.relationship == .owner }
        //            .sorted { lhs, rhs in
        //                lhs.$from.id.uuidString < rhs.$from.id.uuidString
        //            }
        //
        //        guard let ownerRelation = ownerRelations.first else {
        //            return ownerNodeID
        //        }
        //
        //        var nextVisited = visited
        //        nextVisited.insert(ownerNodeID)
        //        return try await deliveryNodeID(
        //            forRemoteOwnerNodeID: ownerRelation.$from.id,
        //            on: database,
        //            visited: nextVisited
        //        )
    }

    func executeActionCallRequest(
        _ request: KeepTalkingActionCallRequest,
        context: KeepTalkingContext?,
        onAcknowledgement:
            (@Sendable (KeepTalkingRequestAckState, String?) async -> Void)? =
            nil,
        assistantPublisher: AIOrchestrator.AssistantPublisher? = nil,
        toolHintPublisher: AIOrchestrator.ToolHintPublisher? = nil
    ) async -> KeepTalkingActionCallResult {
        #if os(macOS)
        // Built-in file-staging preflight: handled before normal action
        // resolution (it has no action record). Stages the streamed file and
        // returns its handle for a subsequent real tool call to reference.
        if request.call.action == Self.stageFileActionID {
            if let onAcknowledgement {
                await onAcknowledgement(.accepted, "Staging file.")
            }
            return await handleStageFilePreflight(request)
        }
        #endif
        // Cross-node cancellation rides the same channel (reserved id, encrypted +
        // authorized like any action call); handled before normal resolution.
        if request.call.action == Self.cancelActionID {
            if let onAcknowledgement {
                await onAcknowledgement(.accepted, "Cancellation received.")
            }

            return handleIncomingCancelRequest(request)
        }

        return await withActionCallActivity(for: request) {
            await performActionCallRequest(
                request,
                context: context,
                onAcknowledgement: onAcknowledgement,
                assistantPublisher: assistantPublisher,
                toolHintPublisher: toolHintPublisher
            )
        }
    }

    private func performActionCallRequest(
        _ request: KeepTalkingActionCallRequest,
        context: KeepTalkingContext?,
        onAcknowledgement:
            (@Sendable (KeepTalkingRequestAckState, String?) async -> Void)?,
        assistantPublisher: AIOrchestrator.AssistantPublisher?,
        toolHintPublisher: AIOrchestrator.ToolHintPublisher?
    ) async -> KeepTalkingActionCallResult {
        let action: KeepTalkingAction
        let grant: KeepTalkingActionScope
        do {
            (action, grant) = try await prepareActionCallExecution(
                request,
                context: context
            )
        } catch {
            if let onAcknowledgement {
                await onAcknowledgement(.rejected, error.localizedDescription)
            }
            return KeepTalkingActionCallResult(
                requestID: request.id,
                contextID: request.contextID,
                callerNodeID: request.callerNodeID,
                targetNodeID: request.targetNodeID,
                actionID: request.call.action,
                content: [],
                isError: true,
                errorMessage: error.localizedDescription
            )
        }

        if let onAcknowledgement {
            await onAcknowledgement(.accepted, "Accepted by target node.")
        }

        do {
            let callResult: (content: [Tool.Content], isError: Bool?)
            // One-time blobs the executor streams back to the caller (filesystem
            // get-file); surfaced on the result for the caller to materialize.
            var outputTransfers: [KeepTalkingOneTimeBlobRef]? = nil
            // Resources this call PRODUCED (summoned attachments + private OTB
            // outputs), in the unified agent-facing format — surfaced on the result.
            var producedResources: [KTResourceManifest.AgentResource] = []
            // Every executor branch merges delivered outputs the same way.
            // Transfers APPEND (never assign): the filesystem branch has
            // already seeded outputTransfers from the op result by the time it
            // harvests produced files.
            func absorb(_ delivered: KeepTalkingIOManager.DeliveredOutputs) {
                producedResources.append(contentsOf: delivered.resources)
                if !delivered.transfers.isEmpty {
                    outputTransfers = (outputTransfers ?? []) + delivered.transfers
                }
            }
            // Narration a plugin executor pushed while running — surfaced on the
            // result so the caller's tool payload can backfeed it to the agent.
            var elucidations: [String]? = nil
            switch action.payload {
                case .plugin:
                    #if os(macOS)
                    // Same IO lifecycle as skills — stage inputs, allocate
                    // workspace output slots, build the manifest — but the
                    // manifest rides the KTPP call frame (resources block +
                    // signed resourcesHash) instead of a subprocess env, and
                    // no sandbox policy is compiled (KT never launches plugin
                    // processes). Harvest stays the fail-closed slot scan.
                    await refreshPluginInstanceDescriptorIfStale(action)
                    let pluginIO = KeepTalkingIOManager(client: self)
                    let pluginRun = try await pluginIO.prepareActionRun(
                        action: action, request: request, grant: grant)
                    defer {
                        pluginIO.cleanup(
                            pluginRun, consumedInputHandles: request.call.inputHandles)
                    }
                    let pluginOutput = try await pluginHost.callActionDetailed(
                        action: action,
                        call: request.call,
                        scope: grant,
                        callerNodeID: request.callerNodeID,
                        contextID: request.contextID,
                        manifest: pluginRun.manifest
                    )
                    callResult = (content: pluginOutput.content, isError: pluginOutput.isError)
                    if !pluginOutput.elucidations.isEmpty {
                        elucidations = pluginOutput.elucidations
                    }
                    let pluginDelivered = await pluginIO.deliverOutputs(
                        pluginRun.outputSlots,
                        contextID: request.contextID,
                        callerNodeID: request.callerNodeID,
                        actionID: request.call.action)
                    absorb(pluginDelivered)
                    let pluginSlotPaths = Set(pluginRun.outputSlots.map(\.path.standardizedFileURL.path))
                    let pluginHarvested = await pluginIO.harvestWorkspaceOutputs(
                        workspaceDirectory: pluginRun.workspaceDirectory,
                        declaredSlotPaths: pluginSlotPaths,
                        contextID: request.contextID,
                        callerNodeID: request.callerNodeID)
                    absorb(pluginHarvested)
                    #else
                    callResult = (content: [], isError: true)
                    #endif
                case .mcpBundle:
                    callResult = try await mcpManager.callAction(
                        action: action,
                        call: request.call,
                        scope: grant
                    )
                case .skill:
                    #if os(macOS)
                    let actionIO = KeepTalkingIOManager(client: self)
                    let ioRun = try await actionIO.prepareActionRun(
                        action: action, request: request, grant: grant)
                    defer {
                        actionIO.cleanup(
                            ioRun, consumedInputHandles: request.call.inputHandles)
                    }
                    callResult = try await skillManager.callAction(
                        action: action,
                        call: request.call,
                        sandboxPolicy: ioRun.sandboxPolicy,
                        model: openAIModel ?? "gpt-5-codex",
                        attachmentsDir: ioRun.attachmentsDir,
                        manifest: ioRun.manifest,
                        workspaceDirectory: ioRun.workspaceDirectory
                    )
                    let delivered = await actionIO.deliverOutputs(
                        ioRun.outputSlots,
                        contextID: request.contextID,
                        callerNodeID: request.callerNodeID,
                        actionID: request.call.action)
                    absorb(delivered)
                    let slotPaths = Set(ioRun.outputSlots.map(\.path.standardizedFileURL.path))
                    let harvested = await actionIO.harvestWorkspaceOutputs(
                        workspaceDirectory: ioRun.workspaceDirectory,
                        declaredSlotPaths: slotPaths,
                        contextID: request.contextID,
                        callerNodeID: request.callerNodeID)
                    absorb(harvested)
                    #else
                    callResult = (content: [], isError: true)
                    #endif
                case .primitive:
                    var call = request.call
                    call.metadata.fields["caller_id"] = .string(request.callerNodeID.uuidString.lowercased())
                    let primitiveResult = try await primitiveActionManager.callAction(
                        action: action,
                        call: call,
                        scope: grant
                    )
                    callResult = (
                        content: primitiveResult.content, isError: primitiveResult.isError
                    )
                    // Route any files the primitive produced (e.g. ask-for-file's
                    // picked files) per the caller's persistence switch into the
                    // unified producedResources — same path as skill/action outputs.
                    if !primitiveResult.outputFiles.isEmpty {
                        // Default to PRIVATE (.otb): a picked file (ask-for-file) is for
                        // the requesting agent, delivered in-band — not auto-broadcast to
                        // every participant. The caller opts into a shared attachment
                        // explicitly via `outputs[].persistence = "attachment"`.
                        let persistence =
                            request.call.outputHandles?.first?.persistence ?? .otb
                        let delivered = await KeepTalkingIOManager(client: self)
                            .deliverProducedOutputFiles(
                                primitiveResult.outputFiles,
                                persistence: persistence,
                                in: request.contextID,
                                to: request.callerNodeID)
                        absorb(delivered)
                        onLog?(
                            "[io/primitive-output] action=\(request.call.action.uuidString.prefix(8)) "
                                + "files=\(primitiveResult.outputFiles.count) "
                                + "persistence=\(persistence.rawValue) "
                                + "produced=\(delivered.resources.count)")
                    }
                case .filesystem:
                    let isLocalExecution = request.callerNodeID == config.node
                    // Materialize streamed one-time blobs ONLY for put-file — the
                    // only op that consumes them. Read ops (ls/read/grep/stat) that
                    // carry spurious inputTransfers must not trigger an
                    // unseal+decrypt+write. Cleanup armed before any materialize.
                    let inputStagingDir = URL(
                        fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
                    ).appendingPathComponent(
                        "kt-otb-fsin-\(request.id.uuidString.lowercased())", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: inputStagingDir) }
                    var inputFiles: [URL] = []
                    let fsOp = filesystemOpAndArguments(request.call).op
                    if fsOp == KeepTalkingFilesystemOperation.putFile.rawValue {
                        for ref in request.call.inputTransfers ?? [] {
                            inputFiles.append(
                                try await materializeOneTimeBlob(
                                    ref, from: request.callerNodeID, into: inputStagingDir))
                        }
                    }
                    let fsResult = try await filesystemActionManager.callAction(
                        action: action,
                        call: request.call,
                        scope: grant,
                        contextID: request.contextID,
                        callerNodeID: request.callerNodeID,
                        isLocalExecution: isLocalExecution,
                        inputFiles: inputFiles
                    )
                    callResult = (content: fsResult.content, isError: fsResult.isError)
                    outputTransfers = fsResult.outputTransfers.isEmpty ? nil : fsResult.outputTransfers
                    // A LOCAL get-file has nothing to stream — the bytes are
                    // already on this disk — but the agent still needs a handle
                    // to pass as another action's `file` input. Stage the file
                    // in place so it surfaces as a $KT_OTB resource, the same
                    // shape a remote get-file ends up with.
                    if !fsResult.producedFiles.isEmpty {
                        let persistence =
                            request.call.outputHandles?.first?.persistence ?? .otb
                        let delivered = await KeepTalkingIOManager(client: self)
                            .deliverProducedOutputFiles(
                                fsResult.producedFiles,
                                persistence: persistence,
                                in: request.contextID,
                                to: request.callerNodeID)
                        absorb(delivered)
                        onLog?(
                            "[io/filesystem-output] action=\(request.call.action.uuidString.prefix(8)) "
                                + "files=\(fsResult.producedFiles.count) "
                                + "persistence=\(persistence.rawValue) "
                                + "produced=\(delivered.resources.count)")
                    }
                case .semanticRetrieval:
                    callResult = try await semanticRetrievalActionManager.callAction(
                        action: action,
                        call: request.call,
                        contextID: request.contextID
                    )
                case .actionCreation:
                    callResult = await executeActionCreationActionCall(
                        action: action,
                        request: request
                    )
                case .acp:
                    #if os(macOS)
                    // The agent runs unsandboxed by design; the scope drives only
                    // advisory containment (advertised fs caps, KT-served fs path
                    // containment, permission auto-policy) inside ACPManager.
                    //
                    // Mid-turn feedback is published under the collaborating
                    // agent's OWN identity, as ordinary messages. It is not
                    // `.thinking`: that type means "the reasoning behind this
                    // assistant's answer" and is dropped from agent-to-agent
                    // context replay — which is exactly the wrong fate for a
                    // collaborator's plan and findings. Speaking as itself, the
                    // agent is simply another participant in the conversation.
                    // The sinks are the orchestrator's own publishers, which know
                    // the turn and context these belong to. A call with neither (a
                    // peer invoking this action directly, a CLI run) simply runs
                    // without narration rather than narrating into a turn it is
                    // not part of.
                    //
                    // The split is by what the update IS. A thought or a plan is
                    // the agent talking, so it speaks as itself. A tool call is a
                    // tool-invocation hint — the same thing `.intermediate` exists
                    // for — so it folds under this action's row and its arguments
                    // are SEALED to the two ends of the call instead of broadcast
                    // as message text to everyone in the context.
                    let agentName = action.actionLabel
                    let acpActionID = action.id
                    var onACPUpdate: (@Sendable (KeepTalkingACPUpdate) async -> Void)?
                    if assistantPublisher != nil || toolHintPublisher != nil {
                        onACPUpdate = { update in
                            switch update.kind {
                                case .toolCall, .toolFailure:
                                    try? await toolHintPublisher?(
                                        agentName,
                                        .intermediate(
                                            hint: update.text,
                                            targetNodeID: nil,
                                            actionID: acpActionID,
                                            actionName: agentName
                                        ),
                                        update.parameters.isEmpty ? nil : update.parameters
                                    )
                                case .thought, .plan:
                                    try? await assistantPublisher?(
                                        (update.text, .message, agentName))
                            }
                        }
                    }
                    callResult = try await acpManager.callAction(
                        action: action,
                        call: request.call,
                        scope: grant,
                        callerIsRemote: request.callerNodeID != config.node,
                        onUpdate: onACPUpdate
                    )
                    #else
                    callResult = (content: [], isError: true)
                    #endif
            }

            let actionID = request.call.action.uuidString.lowercased()
            let source = {
                switch action.payload {
                    case .mcpBundle:
                        return "mcp"
                    case .skill:
                        return "skill"
                    case .primitive:
                        return "primitive"
                    case .filesystem:
                        return "filesystem"
                    case .semanticRetrieval:
                        return "semantic_retrieval"
                    case .actionCreation:
                        return "action_creation"
                    case .acp:
                        return "acp"
                    case .plugin:
                        return "plugin"
                }
            }()
            let rendered = callResult.content.map {
                renderToolContentForDebug($0)
            }.joined(separator: " | ")
            let loggedContent =
                source == "skill"
                ? "<skill-result-redacted>"
                : truncatedActionCallDebug(rendered)
            onLog?(
                "[action-call/result] action=\(actionID) source=\(source) is_error=\(callResult.isError ?? false) content=\(loggedContent)"
            )

            return KeepTalkingActionCallResult(
                requestID: request.id,
                contextID: request.contextID,
                callerNodeID: request.callerNodeID,
                targetNodeID: request.targetNodeID,
                actionID: request.call.action,
                content: callResult.content,
                isError: callResult.isError ?? false,
                errorMessage: nil,
                outputTransfers: outputTransfers,
                producedResources: producedResources.isEmpty ? nil : producedResources,
                elucidations: elucidations
            )
        } catch {
            return KeepTalkingActionCallResult(
                requestID: request.id,
                contextID: request.contextID,
                callerNodeID: request.callerNodeID,
                targetNodeID: request.targetNodeID,
                actionID: request.call.action,
                content: [],
                isError: true,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func prepareActionCallExecution(
        _ request: KeepTalkingActionCallRequest,
        context: KeepTalkingContext?
    ) async throws -> (KeepTalkingAction, KeepTalkingActionScope) {
        let action = try await resolveLocalActionForExecution(
            actionID: request.call.action
        )
        let callerNode = try await ensure(
            request.callerNodeID,
            for: KeepTalkingNode.self
        )

        if action.disabled == true {
            throw KeepTalkingClientError.actionCallNotAuthorized(
                action: request.call.action,
                caller: request.callerNodeID,
                context: request.contextID
            )
        }

        guard
            let grant = try await allowedActionScope(
                node: callerNode,
                action: action,
                context: context
            )
        else {
            throw KeepTalkingClientError.actionCallNotAuthorized(
                action: request.call.action,
                caller: request.callerNodeID,
                context: request.contextID
            )
        }

        // A `.verbs([])` scope grants nothing — treat as denied uniformly across
        // all payloads rather than dispatching to an executor with an empty scope.
        if grant.isDenied {
            throw KeepTalkingClientError.actionCallNotAuthorized(
                action: request.call.action,
                caller: request.callerNodeID,
                context: request.contextID
            )
        }

        // blockingAuthorisation actions from remote callers are now handled via
        // the agentTurnContinuation message channel — the remote agent suspends
        // and B's user responds in-chat.  If this path is reached for such an
        // action it means a legacy or local caller is executing it; fall through
        // to normal execution in that case (local callers still use the approval
        // handler).
        if action.blockingAuthorisation == true,
            request.callerNodeID == config.node,
            let context,
            let actionApprovalHandler
        {
            let approved = await actionApprovalHandler(
                request,
                action,
                context
            )
            guard approved else {
                throw KeepTalkingClientError.actionCallNotAuthorized(
                    action: request.call.action,
                    caller: request.callerNodeID,
                    context: request.contextID
                )
            }
        }

        return (action, grant)
    }

    func handleIncomingActionCallRequest(
        _ request: KeepTalkingActionCallRequest
    ) async throws {
        let requestID = request.id.uuidString.lowercased()
        let actionID = request.call.action.uuidString.lowercased()
        let inFlightTask: Task<KeepTalkingActionCallResult, Never>

        // An envelope off the wire can never legitimately claim to be from this
        // node. A local call short-circuits before transport — `dispatchActionCall`
        // executes it directly when the delivery node is self — and the SFU does
        // not echo a broadcast back to its sender. So a caller ID equal to ours
        // is spoofed, and it is the most valuable identity to spoof: the grants
        // keyed to this node are the self-grants the local agent runs its own
        // tools under, so accepting one would hand a peer the whole local tool
        // surface. Drop it before acknowledging — a spoofer gets no reply.
        guard request.callerNodeID != config.node else {
            onLog?(
                "[action-call/request] refused request=\(requestID) action=\(actionID): caller claims this node's own identity"
            )
            return
        }

        await sendActionCallAcknowledgementBestEffort(
            request,
            state: .received,
            message: "Received by target node."
        )

        // Cross-node cancel rides the same channel but MUST act on the (possibly
        // ACTIVE) target run immediately. Handle it here, synchronously, BEFORE the
        // per-context queue/delegation dispatch below — routing it through the
        // coordinator would queue it behind the very run it is meant to stop (the
        // run holds the context's only active slot), so the cancel could never
        // preempt it. Mirrors the stage-file / cancelled-before-arrival short-circuits.
        if request.call.action == Self.cancelActionID {
            let cancelResult = handleIncomingCancelRequest(request)
            try await sendIncomingActionCallResult(
                cancelResult, requestID: requestID, actionID: actionID)
            return
        }

        // A cancel that raced ahead of this request short-circuits it (no spawn).
        if consumeCancelledBeforeArrival(for: request) {
            onLog?(
                "[action-call/cancel] request=\(requestID) cancelled before arrival; short-circuiting"
            )
            let cancelled = Self.actionCallCancelledResult(request)
            finalizeIncomingActionCall(requestID: request.id, result: cancelled)
            try await sendIncomingActionCallResult(
                cancelled, requestID: requestID, actionID: actionID)
            return
        }

        if let cachedResult = cachedIncomingActionCallResult(for: request.id) {
            onLog?(
                "[action-call/request] duplicate completed request=\(requestID) action=\(actionID) resending cached result"
            )
            try await sendIncomingActionCallResult(
                cachedResult,
                requestID: requestID,
                actionID: actionID
            )
            return
        }

        let existingTask = existingIncomingActionCallTask(for: request.id)
        if let existingTask {
            onLog?(
                "[action-call/request] duplicate in-flight request=\(requestID) action=\(actionID) joining existing execution"
            )
            await sendActionCallAcknowledgementBestEffort(
                request,
                state: .accepted,
                message: "Request is already running on target node."
            )
            inFlightTask = existingTask
        } else {
            onLog?(
                "[action-call/request] handling request=\(requestID) action=\(actionID) caller=\(request.callerNodeID.uuidString.lowercased()) context=\(request.contextID.uuidString.lowercased())"
            )
            let createdTask = Task { [weak self] in
                guard let self else {
                    return Self.actionCallErrorResult(
                        request,
                        error: KeepTalkingClientError.actionCallTimeout(
                            request.id
                        )
                    )
                }
                do {
                    let context = try await self.upsertContext(
                        KeepTalkingContext(id: request.contextID)
                    )
                    let execute: @Sendable () async -> KeepTalkingActionCallResult = {
                        await self.executeActionCallRequest(
                            request,
                            context: context,
                            onAcknowledgement: { state, message in
                                await self.sendActionCallAcknowledgementBestEffort(
                                    request,
                                    state: state,
                                    message: message
                                )
                            }
                        )
                    }
                    // A genuinely DELEGATED (remote-caller) execution runs as a
                    // cancel-only run in the agent coordinator: visible, serialized
                    // per context, and stoppable via the queue or a cross-node
                    // cancel. A local self-call runs inline — it is already nested
                    // under the caller's own run, so re-entering the per-context
                    // queue would deadlock behind the slot that very run holds.
                    if request.callerNodeID != self.config.node {
                        do {
                            return try await self.delegationCoordinator.runDelegatedSync(
                                contextID: request.contextID,
                                label: "delegated action \(actionID)",
                                work: execute
                            )
                        } catch is CancellationError {
                            return Self.actionCallCancelledResult(request)
                        }
                    }
                    return await execute()
                } catch {
                    await self.sendActionCallAcknowledgementBestEffort(
                        request,
                        state: .rejected,
                        message: error.localizedDescription
                    )
                    return Self.actionCallErrorResult(request, error: error)
                }
            }
            storeIncomingActionCallTask(
                createdTask, for: request.id, caller: request.callerNodeID)
            inFlightTask = createdTask
        }

        let result = await inFlightTask.value
        finalizeIncomingActionCall(
            requestID: request.id,
            result: result
        )
        try await sendIncomingActionCallResult(
            result,
            requestID: requestID,
            actionID: actionID
        )
        await runPrimitiveActionPostResultHookIfNeeded(
            actionID: request.call.action,
            call: request.call,
            result: result
        )
    }

    private static func actionCallErrorResult(
        _ request: KeepTalkingActionCallRequest,
        error: Error
    ) -> KeepTalkingActionCallResult {
        KeepTalkingActionCallResult(
            requestID: request.id,
            contextID: request.contextID,
            callerNodeID: request.callerNodeID,
            targetNodeID: request.targetNodeID,
            actionID: request.call.action,
            content: [],
            isError: true,
            errorMessage: error.localizedDescription
        )
    }

    private func sendIncomingActionCallResult(
        _ result: KeepTalkingActionCallResult,
        requestID: String,
        actionID: String
    ) async throws {
        onLog?(
            "[action-call/result] returning request=\(requestID) action=\(actionID) is_error=\(result.isError)"
        )

        try await rtcClient.sendTrustedEnvelope(
            result,
            cryptorSource: trustedEnvelopeCryptorSource()
        )
    }

    private func sendActionCallAcknowledgementBestEffort(
        _ request: KeepTalkingActionCallRequest,
        state: KeepTalkingRequestAckState,
        message: String?
    ) async {
        let acknowledgement = KeepTalkingRequestAck(
            requestID: request.id,
            contextID: request.contextID,
            callerNodeID: request.callerNodeID,
            targetNodeID: request.targetNodeID,
            kind: .actionCall,
            state: state,
            actionID: request.call.action,
            message: message
        )
        let requestID = request.id.uuidString.lowercased()
        let actionID = request.call.action.uuidString.lowercased()
        let messageSuffix = acknowledgementLogMessageSuffix(message)
        onLog?(
            "[action-call/ack] sending request=\(requestID) action=\(actionID) state=\(state.rawValue)\(messageSuffix)"
        )

        do {
            try await rtcClient.sendTrustedEnvelope(
                acknowledgement,
                cryptorSource: trustedEnvelopeCryptorSource()
            )
        } catch {
            onLog?(
                "[action-call/ack] failed request=\(requestID) action=\(actionID) state=\(state.rawValue) error=\(error.localizedDescription)"
            )
        }
    }

    func handleIncomingRequestAck(_ acknowledgement: KeepTalkingRequestAck) {
        guard acknowledgement.kind == .actionCall else {
            return
        }
        let requestID = acknowledgement.requestID.uuidString.lowercased()
        let actionID = acknowledgement.actionID?.uuidString.lowercased() ?? ""
        onLog?(
            "[action-call/ack] received request=\(requestID) action=\(actionID) state=\(acknowledgement.state.rawValue)\(acknowledgementLogMessageSuffix(acknowledgement.message))"
        )
        _ = resolvePendingActionCallAcknowledgement(acknowledgement)
    }

    private func cachedIncomingActionCallResult(for requestID: UUID)
        -> KeepTalkingActionCallResult?
    {
        actionCallQueue.sync {
            completedIncomingActionCallResults[requestID]
        }
    }

    private func existingIncomingActionCallTask(for requestID: UUID)
        -> Task<KeepTalkingActionCallResult, Never>?
    {
        actionCallQueue.sync {
            inFlightIncomingActionCalls[requestID]
        }
    }

    private func storeIncomingActionCallTask(
        _ task: Task<KeepTalkingActionCallResult, Never>,
        for requestID: UUID,
        caller: UUID
    ) {
        actionCallQueue.sync {
            inFlightIncomingActionCalls[requestID] = task
            incomingActionCallCallers[requestID] = caller
        }
    }

    private func finalizeIncomingActionCall(
        requestID: UUID,
        result: KeepTalkingActionCallResult
    ) {
        actionCallQueue.sync {
            inFlightIncomingActionCalls.removeValue(forKey: requestID)
            incomingActionCallCallers.removeValue(forKey: requestID)
            completedIncomingActionCallResults[requestID] = result
            completedIncomingActionCallOrder.removeAll {
                $0 == requestID
            }
            completedIncomingActionCallOrder.append(requestID)
            while completedIncomingActionCallOrder.count
                > Self.completedIncomingActionCallCacheLimit
            {
                let evicted = completedIncomingActionCallOrder.removeFirst()
                completedIncomingActionCallResults.removeValue(
                    forKey: evicted
                )
            }
        }
    }

    func dispatchActionCall(
        actionOwner: UUID,
        call: KeepTalkingActionCall,
        context: KeepTalkingContext,
        agentTurnID: UUID? = nil,
        assistantPublisher: AIOrchestrator.AssistantPublisher? = nil,
        toolHintPublisher: AIOrchestrator.ToolHintPublisher? = nil
    ) async throws -> KeepTalkingActionCallResult {
        // TODO: This is a bug
        let deliveryNodeID = try await deliveryNodeID(
            forRemoteOwnerNodeID: actionOwner
        )

        let request = KeepTalkingActionCallRequest(
            contextID: try context.requireID(),
            callerNodeID: config.node,
            targetNodeID: deliveryNodeID,
            call: call
        )
        let requestID = request.id.uuidString.lowercased()
        let actionID = call.action.uuidString.lowercased()

        if deliveryNodeID == config.node {
            onLog?(
                "[action-call/request] executing locally request=\(requestID) action=\(actionID)"
            )
            let result = await executeActionCallRequest(
                request,
                context: context,
                assistantPublisher: assistantPublisher,
                toolHintPublisher: toolHintPublisher
            )
            await runPrimitiveActionPostResultHookIfNeeded(
                actionID: call.action,
                call: call,
                result: result
            )

            return result
        }

        return try await withActionCallActivity(for: request) {
            try await withStagingResources(for: request) { stagedRequest in
                try await dispatchRemoteActionCall(
                    actionOwner: actionOwner,
                    request: stagedRequest,
                    context: context,
                    agentTurnID: agentTurnID
                )
            }
        }
    }

    private func dispatchRemoteActionCall(
        actionOwner: UUID,
        request: KeepTalkingActionCallRequest,
        context: KeepTalkingContext,
        agentTurnID: UUID?
    ) async throws -> KeepTalkingActionCallResult {
        let call = request.call
        let deliveryNodeID = request.targetNodeID
        let requestID = request.id.uuidString.lowercased()
        let actionID = call.action.uuidString.lowercased()

        // Remote blocking actions use the continuation model instead of the
        // synchronous action-call channel. The agent turn suspends until the
        // remote user responds via the in-chat widget.
        if await shouldUseWakeAssistedDelivery(for: call.action), let agentTurnID {
            return try await dispatchBlockingActionCallViaContinuation(
                request: request,
                context: context,
                agentTurnID: agentTurnID
            )
        }

        onLog?(
            "[action-call/request] dispatching remote request=\(requestID) action=\(actionID) owner=\(actionOwner.uuidString.lowercased()) target=\(deliveryNodeID.uuidString.lowercased()) context=\(request.contextID.uuidString.lowercased())"
        )

        try await sendRemoteActionCallRequest(request, deliveryDescription: "rtc")

        return try await withTaskCancellationHandler {
            try await waitForActionCallResult(
                requestID: request.id,
                targetNodeID: deliveryNodeID
            )
        } onCancel: {
            // The caller's run was cancelled — tell the provider to stop too, so a
            // long remote run isn't orphaned. Local unwind happens via the throw.
            self.sendCancelFireAndForget(
                requestID: request.id,
                targetNodeID: deliveryNodeID,
                contextID: request.contextID)
        }
    }

    private func withActionCallActivity(
        for request: KeepTalkingActionCallRequest,
        operation: () async throws -> KeepTalkingActionCallResult
    ) async rethrows -> KeepTalkingActionCallResult {
        await onActionCallActivity?(.init(request: request, phase: .began))
        do {
            let result = try await operation()
            await onActionCallActivity?(
                .init(
                    request: request,
                    phase: .ended(result.isError ? .failure : .success)
                )
            )

            return result
        } catch {
            await onActionCallActivity?(.init(request: request, phase: .ended(.failure)))
            throw error
        }
    }

    private func dispatchBlockingActionCallViaContinuation(
        request: KeepTalkingActionCallRequest,
        context: KeepTalkingContext,
        agentTurnID: UUID
    ) async throws -> KeepTalkingActionCallResult {
        let call = request.call
        let actionID = call.action.uuidString.lowercased()
        let targetNodeID = request.targetNodeID
        onLog?(
            "[action-call/continuation] suspending agentTurnID=\(agentTurnID.uuidString.lowercased()) action=\(actionID) target=\(targetNodeID.uuidString.lowercased())"
        )

        // Encrypt the full action call request for the target node.
        let encryptedRequest = try await encryptActionCallRequestEnvelope(request)

        // Look up action kind for the `kind` label in the continuation message.
        let kind: String
        if let action = try? await KeepTalkingAction.find(call.action, on: localStore.database) {
            kind =
                switch action.payload {
                    case .primitive(let b): b.action.rawValue
                    case .mcpBundle: "mcp"
                    case .skill: "skill"
                    case .filesystem: "filesystem"
                    case .semanticRetrieval: "semantic_retrieval"
                    case .actionCreation: "action_creation"
                    case .acp: "acp"
                    case .plugin: "plugin"
                }
        } else {
            kind = actionID
        }

        let selfNode = try await getCurrentNodeInstance()
        let selfNodeID = try selfNode.requireID()
        let sender = KeepTalkingContextMessage.Sender.node(node: selfNodeID)

        // Push-wake the target node in case it's offline, then suspend.
        await sendActionWakeIfNeeded(
            actionOwner: targetNodeID,
            call: call,
            context: context
        )

        let continuationResult = try await suspendAgentTurnForContinuation(
            agentTurnID: agentTurnID,
            toolCallID: request.id.uuidString.lowercased(),
            actionID: call.action,
            targetNodeID: targetNodeID,
            kind: kind,
            encryptedPayload: encryptedRequest.ciphertext,
            context: context,
            sender: sender
        )

        // Carry the produced resources + output transfers the target computed
        // (e.g. a remote ask-for-file's picked file) all the way back — the
        // staging scaffold handles them the same way as direct delivery.
        return KeepTalkingActionCallResult(
            requestID: request.id,
            contextID: request.contextID,
            callerNodeID: config.node,
            targetNodeID: targetNodeID,
            actionID: call.action,
            content: continuationResult.content,
            isError: continuationResult.content.isEmpty,
            outputTransfers: continuationResult.outputTransfers,
            producedResources: continuationResult.producedResources
        )
    }

    func sendRemoteActionCallRequest(
        _ request: KeepTalkingActionCallRequest,
        deliveryDescription: String
    ) async throws {
        let requestID = request.id.uuidString.lowercased()
        let actionID = request.call.action.uuidString.lowercased()

        for attempt in 1...Self.actionCallAckRetryLimit {
            onLog?(
                "[action-call/request] sending request=\(requestID) action=\(actionID) attempt=\(attempt) delivery=\(deliveryDescription)"
            )
            try await rtcClient.sendTrustedEnvelope(
                request,
                cryptorSource: trustedEnvelopeCryptorSource()
            )

            let acknowledgement = try await waitForActionCallAcknowledgement(
                requestID: request.id,
                timeoutSeconds: Self.actionCallAckTimeoutSeconds
            )
            if acknowledgement != nil {
                return
            }
            if cachedReceivedActionCallResult(for: request.id) != nil {
                onLog?(
                    "[action-call/ack] missing request=\(requestID) action=\(actionID) but result already arrived"
                )
                return
            }
            guard attempt < Self.actionCallAckRetryLimit else {
                onLog?(
                    "[action-call/ack] missing request=\(requestID) action=\(actionID) after=\(Int(Self.actionCallAckTimeoutSeconds))s"
                )
                return
            }

            onLog?(
                "[action-call/ack] missing request=\(requestID) action=\(actionID) after=\(Int(Self.actionCallAckTimeoutSeconds))s; retrying on reliable route"
            )
            rtcClient.preferReliableRoute(
                reason: "missing action-call ack request=\(requestID)"
            )
        }
    }

    func waitForActionCallAcknowledgement(
        requestID: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> KeepTalkingRequestAck? {
        if let acknowledgement = consumeReceivedActionCallAcknowledgement(
            for: requestID
        ) {
            return acknowledgement
        }

        return try await withThrowingTaskGroup(
            of: KeepTalkingRequestAck?.self
        ) { group in
            group.addTask { [weak self] in
                guard let self else {
                    return nil
                }
                return try await withTaskCancellationHandler(
                    operation: {
                        try await withCheckedThrowingContinuation {
                            (
                                continuation: CheckedContinuation<
                                    KeepTalkingRequestAck, Error
                                >
                            ) in
                            self.actionCallQueue.sync {
                                if let acknowledgement =
                                    self
                                    .consumeReceivedActionCallAcknowledgementLocked(
                                        for: requestID
                                    )
                                {
                                    continuation.resume(
                                        returning: acknowledgement
                                    )
                                    return
                                }
                                self.pendingActionCallAcknowledgements[
                                    requestID
                                ] = continuation
                            }
                        }
                    },
                    onCancel: {
                        self.cancelPendingActionCallAcknowledgement(
                            requestID: requestID
                        )
                    }
                )
            }

            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)
                )
                return nil
            }

            let first = try await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }

    /// Waits for a remote action-call result *patiently*. For the first
    /// `actionCallResultGraceSeconds` it simply waits; after that it polls the
    /// target node's liveness every `actionCallResultPollSeconds` and keeps
    /// waiting indefinitely while the node stays online — only giving up with
    /// `actionCallTargetOffline` once the node drops. The wait is
    /// cancellation-aware: when the agent run is aborted, the parent task is
    /// cancelled, the pending continuation is resolved immediately via
    /// `failPendingActionCall`, and the wait unwinds rather than leaking.
    func waitForActionCallResult(
        requestID: UUID,
        targetNodeID: UUID
    ) async throws -> KeepTalkingActionCallResult {
        if let cachedResult = consumeReceivedActionCallResult(for: requestID) {
            return cachedResult
        }

        return try await patientWait(
            label: "action-call result request=\(requestID.uuidString.lowercased())",
            graceSeconds: Self.actionCallResultGraceSeconds,
            pollSeconds: Self.actionCallResultPollSeconds,
            log: onLog,
            isAlive: { [weak self] in
                guard let self else { return false }
                // Local executions never reach this path, but treat the self
                // node as always-alive for safety.
                if targetNodeID == self.config.node { return true }
                return self.isNodeOnline(targetNodeID)
            },
            onDeath: {
                KeepTalkingClientError.actionCallTargetOffline(
                    requestID: requestID,
                    targetNodeID: targetNodeID
                )
            }
        ) { [weak self] in
            guard let self else {
                throw KeepTalkingClientError.clientDisconnected
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (
                        continuation: CheckedContinuation<
                            KeepTalkingActionCallResult, Error
                        >
                    ) in
                    self.actionCallQueue.sync {
                        if let cachedResult =
                            self.consumeReceivedActionCallResultLocked(
                                for: requestID
                            )
                        {
                            continuation.resume(returning: cachedResult)
                            return
                        }
                        self.pendingActionCallResults[requestID] = continuation
                    }
                }
            } onCancel: {
                // Parent task aborted (e.g. user cancelled the agent run) or the
                // patient watchdog gave up: resolve the pending continuation now
                // so the wait can't hang on a leaked entry.
                self.failPendingActionCall(
                    requestID: requestID,
                    error: CancellationError()
                )
            }
        }
    }

    func resolvePendingActionCall(_ result: KeepTalkingActionCallResult)
        -> Bool
    {
        actionCallQueue.sync {
            if let continuation = pendingActionCallResults.removeValue(
                forKey: result.requestID
            ) {
                continuation.resume(returning: result)
                return true
            }

            storeReceivedActionCallResultLocked(result)
            return false
        }
    }

    func resolvePendingActionCallAcknowledgement(
        _ acknowledgement: KeepTalkingRequestAck
    ) -> Bool {
        actionCallQueue.sync {
            if let continuation =
                pendingActionCallAcknowledgements
                .removeValue(forKey: acknowledgement.requestID)
            {
                continuation.resume(returning: acknowledgement)
                return true
            }

            storeReceivedActionCallAcknowledgementLocked(acknowledgement)
            return false
        }
    }

    private func shouldUseWakeAssistedDelivery(for actionID: UUID) async -> Bool {
        guard
            let action = try? await KeepTalkingAction.query(on: localStore.database)
                .filter(\.$id, .equal, actionID)
                .first()
        else {
            return false
        }
        // Filesystem actions must take the direct remote branch so OTB transfers
        // are streamed/materialized — the continuation path doesn't carry them.
        // (iOS forces blockingAuthorisation=true for ALL actions, so without
        // this a remote get/put-file would silently no-op there.)
        if case .filesystem = action.payload { return false }
        return action.blockingAuthorisation == true
    }

    func failPendingActionCall(requestID: UUID, error: Error) {
        actionCallQueue.sync {
            if let continuation = pendingActionCallResults.removeValue(
                forKey: requestID
            ) {
                continuation.resume(throwing: error)
            }
            if let continuation =
                pendingActionCallAcknowledgements
                .removeValue(forKey: requestID)
            {
                continuation.resume(throwing: error)
            }
        }
    }

    func failAllPendingActionCalls(error: Error) {
        actionCallQueue.sync {
            let pendingResults = pendingActionCallResults
            let pendingAcknowledgements = pendingActionCallAcknowledgements
            pendingActionCallResults.removeAll()
            pendingActionCallAcknowledgements.removeAll()
            receivedActionCallResults.removeAll()
            receivedActionCallResultOrder.removeAll()
            receivedActionCallAcknowledgements.removeAll()
            receivedActionCallAcknowledgementOrder.removeAll()
            for continuation in pendingResults.values {
                continuation.resume(throwing: error)
            }
            for continuation in pendingAcknowledgements.values {
                continuation.resume(throwing: error)
            }
        }
    }

    private func consumeReceivedActionCallAcknowledgement(for requestID: UUID)
        -> KeepTalkingRequestAck?
    {
        actionCallQueue.sync {
            consumeReceivedActionCallAcknowledgementLocked(for: requestID)
        }
    }

    private func consumeReceivedActionCallAcknowledgementLocked(
        for requestID: UUID
    ) -> KeepTalkingRequestAck? {
        let acknowledgement = receivedActionCallAcknowledgements.removeValue(
            forKey: requestID
        )
        if acknowledgement != nil {
            receivedActionCallAcknowledgementOrder.removeAll {
                $0 == requestID
            }
        }
        return acknowledgement
    }

    private func cancelPendingActionCallAcknowledgement(requestID: UUID) {
        actionCallQueue.sync {
            guard
                let continuation =
                    pendingActionCallAcknowledgements
                    .removeValue(forKey: requestID)
            else {
                return
            }
            continuation.resume(throwing: CancellationError())
        }
    }

    private func storeReceivedActionCallAcknowledgementLocked(
        _ acknowledgement: KeepTalkingRequestAck
    ) {
        receivedActionCallAcknowledgements[acknowledgement.requestID] =
            acknowledgement
        receivedActionCallAcknowledgementOrder.removeAll {
            $0 == acknowledgement.requestID
        }
        receivedActionCallAcknowledgementOrder.append(
            acknowledgement.requestID
        )
        while receivedActionCallAcknowledgementOrder.count
            > Self.actionCallDeliveryCacheLimit
        {
            let evicted = receivedActionCallAcknowledgementOrder.removeFirst()
            receivedActionCallAcknowledgements.removeValue(forKey: evicted)
        }
    }

    private func consumeReceivedActionCallResult(for requestID: UUID)
        -> KeepTalkingActionCallResult?
    {
        actionCallQueue.sync {
            consumeReceivedActionCallResultLocked(for: requestID)
        }
    }

    private func cachedReceivedActionCallResult(for requestID: UUID)
        -> KeepTalkingActionCallResult?
    {
        actionCallQueue.sync {
            receivedActionCallResults[requestID]
        }
    }

    private func consumeReceivedActionCallResultLocked(for requestID: UUID)
        -> KeepTalkingActionCallResult?
    {
        let result = receivedActionCallResults.removeValue(forKey: requestID)
        if result != nil {
            receivedActionCallResultOrder.removeAll {
                $0 == requestID
            }
        }
        return result
    }

    private func storeReceivedActionCallResultLocked(
        _ result: KeepTalkingActionCallResult
    ) {
        receivedActionCallResults[result.requestID] = result
        receivedActionCallResultOrder.removeAll {
            $0 == result.requestID
        }
        receivedActionCallResultOrder.append(result.requestID)
        while receivedActionCallResultOrder.count
            > Self.actionCallDeliveryCacheLimit
        {
            let evicted = receivedActionCallResultOrder.removeFirst()
            receivedActionCallResults.removeValue(forKey: evicted)
        }
    }

    private func acknowledgementLogMessageSuffix(_ message: String?) -> String {
        let trimmed = message?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let trimmed, !trimmed.isEmpty else {
            return ""
        }
        return " message=\(trimmed)"
    }

    func runPrimitiveActionPostResultHookIfNeeded(
        actionID: UUID,
        call: KeepTalkingActionCall,
        result: KeepTalkingActionCallResult
    ) async {
        guard !result.isError else {
            return
        }
        guard
            let action = try? await resolveLocalActionForExecution(
                actionID: actionID
            ),
            case .primitive(let primitive) = action.payload
        else {
            return
        }
        primitiveActionPostResultHandler?(primitive, call)
    }

    func resolveLocalActionForExecution(actionID: UUID) async throws
        -> KeepTalkingAction
    {
        guard
            let action = try await KeepTalkingAction.query(
                on: localStore.database
            )
            .filter(\.$id, .equal, actionID)
            .filter(\.$node.$id, .equal, config.node)
            .first()
        else {
            throw KeepTalkingClientError.actionNotHostedLocally(actionID)
        }
        return action
    }

    public static func isActionGrantedToNode(
        node: KeepTalkingNode,
        action: KeepTalkingAction,
        context: KeepTalkingContext?,
        selfNode: KeepTalkingNode,
        on database: any Database
    ) async throws -> Bool {
        _ = try selfNode.requireID()
        guard
            let scope = try await allowedActionScope(
                node: node,
                action: action,
                context: context,
                on: database
            )
        else {
            return false
        }
        return !scope.isDenied
    }

    public func isActionGrantedToNode(
        node: KeepTalkingNode,
        action: KeepTalkingAction,
        context: KeepTalkingContext?
    ) async throws -> Bool {
        try await Self.isActionGrantedToNode(
            node: node,
            action: action,
            context: context,
            selfNode: getCurrentNodeInstance(),
            on: localStore.database
        )
    }

    public func isNodeAuthorizedToGrantAction(
        node: KeepTalkingNode,
        context: KeepTalkingContext?
    ) async throws -> Bool {
        let nodeID = try node.requireID()
        if nodeID == config.node {
            return true
        }

        let selfNode = try await getCurrentNodeInstance()
        let relations = try await selfNode.$outgoingNodeRelations
            .query(on: localStore.database)
            .filter(\.$to.$id == nodeID)
            .all()

        return relations.contains { relation in
            relation.allows(context: context)
        }
    }

    func grantedActions(
        _ actions: [KeepTalkingAction],
        for node: KeepTalkingNode,
        context: KeepTalkingContext?
    ) async throws -> [KeepTalkingAction] {
        var allowed: [KeepTalkingAction] = []
        allowed.reserveCapacity(actions.count)

        for action in actions {
            if action.disabled == true { continue }
            guard
                try await isActionGrantedToNode(
                    node: node,
                    action: action,
                    context: context
                )
            else {
                continue
            }
            allowed.append(action)
        }

        return allowed
    }

    private func renderToolContentForDebug(_ content: Tool.Content) -> String {
        switch content {
            case .text(let text, let annotations, let metadata):
                return """
                    text: \(text)
                    annotations: \(annotations.debugDescription)
                    metadata: \(metadata.debugDescription)
                    """
            default:
                if let data = try? JSONEncoder().encode(content),
                    let json = String(data: data, encoding: .utf8)
                {
                    return json
                }
                return "<non-text content>"
        }
    }

    private func truncatedActionCallDebug(_ payload: String) -> String {
        let maxCharacters = 2_000
        guard payload.count > maxCharacters else {
            return payload
        }
        return String(payload.prefix(maxCharacters)) + "...[truncated]"
    }

}
