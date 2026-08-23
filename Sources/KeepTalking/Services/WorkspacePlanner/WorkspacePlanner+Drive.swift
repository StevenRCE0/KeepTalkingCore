//
//  WorkspacePlanner+Drive.swift
//  KeepTalking
//
//  The workspace planner's model/tool turn loop. Runs the open session until
//  it terminates — `kt_finalize` or `kt_refuse` — dispatching each tool call
//  and persisting accumulated atoms back onto the session so
//  `continuePlanning` can revise instead of starting over.
//
//  Collaboration level ONLY: no shell, no probes, no sandbox scope. Building
//  an individual action is `KeepTalkingSkillPlanner`'s loop, chained by the
//  app after this plan is accepted.
//

import AIProxy
import Foundation
import MCP

extension KeepTalkingWorkspacePlanner {

    /// Runs the model/tool loop on the open session until it terminates.
    /// Assumes serial use — the host gates new turns on the previous one
    /// completing (the palette disables its composer while planning).
    func drive(
        onEvent: (@Sendable (KeepTalkingWorkspacePlannerEvent) async -> String?)?
    ) async throws -> KeepTalkingWorkspacePlannerResult {
        guard let run else { throw KeepTalkingWorkspacePlannerError.noActiveSession }

        var messages = run.messages
        var contextName = run.contextName
        var contextDescription = run.contextDescription
        var tags = run.tags
        var peers = run.peers
        var actions = run.actions
        var sideNotes = run.sideNotes
        var rationale = run.rationale
        var finalized = false

        // Writes the working state back onto the session so the next
        // continuePlanning turn revises from here. Called on every terminal
        // path that can be continued (a finalized plan, or a refusal the user
        // may argue with).
        func persist() {
            run.messages = messages
            run.contextName = contextName
            run.contextDescription = contextDescription
            run.tags = tags
            run.peers = peers
            run.actions = actions
            run.sideNotes = sideNotes
            run.rationale = rationale
        }

        /// Finds an existing peer slot by alias, or opens a new one. Alias
        /// identity keeps slot UUIDs stable across revisions, which is what
        /// lets the app's record preserve bindings through `revise`.
        func peerSlot(
            alias: String, expectedCapabilities: [String]? = nil
        ) -> KeepTalkingWorkspacePlan.Peer {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = peers.firstIndex(where: {
                $0.alias.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                if let expectedCapabilities, !expectedCapabilities.isEmpty {
                    peers[index].expectedCapabilities = expectedCapabilities
                }
                return peers[index]
            }
            let created = KeepTalkingWorkspacePlan.Peer(
                alias: trimmed,
                expectedCapabilities: expectedCapabilities ?? []
            )
            peers.append(created)
            return created
        }

        /// Upserts an action slot by (name, source shape). Same-identity
        /// re-proposals keep their UUID so fulfillments survive revisions.
        func upsertAction(
            name: String, description: String?, source: KeepTalkingWorkspacePlan.Action.Source
        ) {
            let sameShape: (KeepTalkingWorkspacePlan.Action) -> Bool = { existing in
                guard existing.name.caseInsensitiveCompare(name) == .orderedSame else {
                    return false
                }
                switch (existing.source, source) {
                    case (.existing, .existing), (.create, .create),
                        (.fromPeer, .fromPeer):
                        return true
                    default:
                        return false
                }
            }
            if let index = actions.firstIndex(where: sameShape) {
                actions[index].description = description ?? actions[index].description
                actions[index].source = source
            } else {
                actions.append(
                    KeepTalkingWorkspacePlan.Action(
                        name: name, description: description, source: source))
            }
        }

        func decodeArguments(_ raw: String) -> [String: MCP.Value] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [:] }
            return (try? JSONDecoder().decode([String: MCP.Value].self, from: data)) ?? [:]
        }
        func string(_ value: MCP.Value?) -> String? {
            guard case .string(let s) = value else { return nil }
            return s
        }
        func arrayOfStrings(_ value: MCP.Value?) -> [String] {
            guard case .array(let arr) = value else { return [] }
            return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }

        var nudged = false
        for _ in 0..<Self.maxTurns {
            let turn = try await aiConnector.completeTurn(
                messages: messages,
                tools: run.tools,
                model: model,
                toolChoice: nil,
                stage: .planning,
                toolExecutor: nil
            )

            if turn.toolCalls.isEmpty {
                // Model stopped calling tools — nudge it once to finalize.
                if !finalized && !nudged {
                    nudged = true
                    if let assistantMsg = assistantMessage(from: turn) {
                        messages.append(assistantMsg)
                    }
                    messages.append(
                        .user(
                            "You must call kt_finalize now to complete the plan. "
                                + "Record any remaining atoms first, then call kt_finalize "
                                + "with a rationale."
                        )
                    )
                    continue
                }
                break
            }

            if let assistantMsg = assistantMessage(from: turn) {
                messages.append(assistantMsg)
            }

            var toolResults: [AIMessage] = []

            for call in turn.toolCalls {
                let args = decodeArguments(call.argumentsJSON)
                var result: String

                switch call.name {

                    case Self.proposeContextTool:
                        let name = (string(args["name"]) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else {
                            result = "Error: `name` must not be empty."
                            break
                        }
                        contextName = name
                        contextDescription = string(args["description"])
                        _ = await onEvent?(.proposingContext(name: name))
                        result = "Context proposed: \(name)"

                    case Self.proposeTagsTool:
                        let proposed = arrayOfStrings(args["tags"])
                            .map {
                                $0.lowercased()
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            .filter { !$0.isEmpty }
                        // Canonicalise against the user's vocabulary so a
                        // case/spacing variant of an existing tag never lands
                        // as a near-duplicate label.
                        let vocabulary = run.existingTags
                        var matched: [String] = []
                        var novel: [String] = []
                        for tag in proposed {
                            let canonical =
                                vocabulary.first {
                                    $0.caseInsensitiveCompare(tag) == .orderedSame
                                } ?? tag
                            if vocabulary.contains(canonical) {
                                matched.append(canonical)
                            } else {
                                novel.append(canonical)
                            }
                            if !tags.contains(canonical) { tags.append(canonical) }
                        }
                        _ = await onEvent?(.proposingTags(tags: matched + novel))
                        if novel.isEmpty || vocabulary.isEmpty {
                            result = "Tags recorded: \(tags.joined(separator: ", "))"
                        } else {
                            result =
                                "Tags recorded: \(tags.joined(separator: ", ")). "
                                + "NOTE: \(novel.joined(separator: ", ")) are NEW — not in the "
                                + "user's vocabulary. Keep them only if no existing tag covers "
                                + "the topic; otherwise kt_remove them and select existing ones."
                        }

                    case Self.proposeGhostPeerTool:
                        let alias = (string(args["alias"]) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !alias.isEmpty else {
                            result = "Error: `alias` must not be empty."
                            break
                        }
                        let capabilities = arrayOfStrings(args["expected_capabilities"])
                        _ = peerSlot(alias: alias, expectedCapabilities: capabilities)
                        _ = await onEvent?(.proposingGhostPeer(alias: alias))
                        result = "Ghost peer slot open: \"\(alias)\""

                    case Self.useExistingActionTool:
                        let idString = string(args["action_id"]) ?? ""
                        let name = string(args["name"]) ?? idString
                        guard let actionID = UUID(uuidString: idString),
                            let inventoryRow = run.existingActions.first(where: {
                                $0.id == actionID
                            })
                        else {
                            result =
                                "Error: '\(idString)' is not in the existing-actions inventory. "
                                + "Use kt_propose_new_action if it must be created."
                            break
                        }
                        upsertAction(
                            name: inventoryRow.name,
                            description: inventoryRow.indexDescription,
                            source: .existing(actionID: actionID)
                        )
                        _ = await onEvent?(.proposingAction(name: name, kind: "existing"))
                        result = "Slotted existing action: \(inventoryRow.name)"

                    case Self.proposeNewActionTool:
                        let name = (string(args["name"]) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let description = string(args["description"])
                        guard !name.isEmpty else {
                            result = "Error: `name` must not be empty."
                            break
                        }
                        upsertAction(name: name, description: description, source: .create)
                        _ = await onEvent?(.proposingAction(name: name, kind: "create"))
                        result = "Action to create recorded: \(name)"

                    case Self.proposePeerActionTool:
                        let name = (string(args["name"]) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let description = string(args["description"])
                        let alias = (string(args["ghost_alias"]) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, !alias.isEmpty else {
                            result = "Error: `name` and `ghost_alias` must not be empty."
                            break
                        }
                        let slot = peerSlot(alias: alias)
                        upsertAction(
                            name: name,
                            description: description,
                            source: .fromPeer(peerID: slot.id)
                        )
                        _ = await onEvent?(.proposingAction(name: name, kind: "peer"))
                        result = "Peer action recorded: \(name) from \"\(alias)\""

                    case Self.grantToPeerTool:
                        let actionName = (string(args["action_name"]) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let alias = (string(args["ghost_alias"]) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !actionName.isEmpty, !alias.isEmpty else {
                            result = "Error: `action_name` and `ghost_alias` must not be empty."
                            break
                        }
                        guard
                            let action = actions.first(where: {
                                $0.name.caseInsensitiveCompare(actionName) == .orderedSame
                            })
                        else {
                            result =
                                "Error: no action named '\(actionName)'. "
                                + "Propose it first with kt_use_existing_action or kt_propose_new_action."
                            break
                        }
                        switch action.source {
                            case .existing, .create:
                                let slot = peerSlot(alias: alias)
                                if let idx = peers.firstIndex(where: { $0.id == slot.id }),
                                    !peers[idx].grantedActions.contains(action.id)
                                {
                                    peers[idx].grantedActions.append(action.id)
                                }
                                _ = await onEvent?(
                                    .grantingAction(name: actionName, toPeer: alias))
                                result = "Granted \"\(actionName)\" to peer \"\(alias)\""
                            case .fromPeer:
                                result =
                                    "Error: cannot grant a peer-sourced action to another peer. "
                                    + "Only local actions (existing or create) can be granted."
                        }

                    case Self.proposeSideNoteTool:
                        let key = (string(args["key"]) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let value = string(args["value"]) ?? ""
                        guard !key.isEmpty, !value.isEmpty else {
                            result = "Error: `key` and `value` must not be empty."
                            break
                        }
                        if let index = sideNotes.firstIndex(where: { $0.key == key }) {
                            sideNotes[index].value = value
                        } else {
                            sideNotes.append(.init(key: key, value: value))
                        }
                        _ = await onEvent?(.proposingSideNote(key: key))
                        result = "Side note recorded: \(key)"

                    case Self.removeTool:
                        let kind = (string(args["kind"]) ?? "").lowercased()
                        let identity = (string(args["identity"]) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        switch kind {
                            case "action":
                                let removedIDs = Set(
                                    actions.filter {
                                        $0.name.caseInsensitiveCompare(identity) == .orderedSame
                                    }.map(\.id)
                                )
                                actions.removeAll {
                                    $0.name.caseInsensitiveCompare(identity) == .orderedSame
                                }
                                for i in peers.indices {
                                    peers[i].grantedActions.removeAll { removedIDs.contains($0) }
                                }
                                result = "Removed action: \(identity)"
                            case "ghost_peer":
                                let removed = peers.filter {
                                    $0.alias.caseInsensitiveCompare(identity) == .orderedSame
                                }
                                peers.removeAll {
                                    $0.alias.caseInsensitiveCompare(identity) == .orderedSame
                                }
                                // Orphaned peer-action slots go with their ghost.
                                let removedIDs = Set(removed.map(\.id))
                                actions.removeAll {
                                    if case .fromPeer(let peerID) = $0.source {
                                        return removedIDs.contains(peerID)
                                    }
                                    return false
                                }
                                result = "Removed ghost peer: \(identity)"
                            case "tag":
                                tags.removeAll { $0 == identity.lowercased() }
                                result = "Removed tag: \(identity)"
                            case "side_note":
                                sideNotes.removeAll { $0.key == identity }
                                result = "Removed side note: \(identity)"
                            default:
                                result =
                                    "Error: unknown kind '\(kind)'. Valid: action, ghost_peer, tag, side_note."
                        }

                    case Self.askUserTool:
                        let question = string(args["question"]) ?? ""
                        let qContext = string(args["context"]) ?? ""
                        let answer = await onEvent?(
                            .askingUser(question: question, context: qContext))
                        if let answer, !answer.isEmpty {
                            result = "User answered: \(answer)"
                        } else {
                            result =
                                "User did not answer. Proceed with your best judgement, "
                                + "or call kt_refuse if you cannot."
                        }

                    case KeepTalkingClient.webSearchFunctionName:
                        let query = (string(args["query"]) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !query.isEmpty else {
                            result = "Error: web_search needs a non-empty `query`."
                            break
                        }
                        guard let webSearchProvider else {
                            result = "Error: web search is not configured."
                            break
                        }
                        _ = await onEvent?(.searchingWeb(query: query))
                        do {
                            result = try await webSearchProvider(query)
                        } catch {
                            result = "Error: web search failed — \(error.localizedDescription)"
                        }

                    case Self.refuseTool:
                        let reason = string(args["reason"]) ?? "Planner declined."
                        let category = KeepTalkingSkillPlannerDeclineKind(
                            rawCategory: string(args["category"]))
                        _ = await onEvent?(.refusing(reason: reason, category: category))
                        // Flush this turn's tool results so the transcript stays
                        // valid if the user argues back next turn.
                        toolResults.append(.tool("Declined.", toolCallID: call.id))
                        messages.append(contentsOf: toolResults)
                        persist()
                        return .refused(reason: reason, category: category)

                    case Self.finalizeTool:
                        guard contextName != nil else {
                            result =
                                "Error: no context proposed yet. Call kt_propose_context "
                                + "before kt_finalize."
                            break
                        }
                        rationale = string(args["rationale"]) ?? ""
                        _ = await onEvent?(.finalizing)
                        finalized = true
                        result = "Done."

                    default:
                        result = "Unknown tool: \(call.name)"
                }

                toolResults.append(.tool(result, toolCallID: call.id))
            }

            messages.append(contentsOf: toolResults)
            if finalized { break }
        }

        guard finalized, let finalContextName = contextName else {
            throw KeepTalkingWorkspacePlannerError.planNotFinalized
        }

        persist()

        return .plan(
            KeepTalkingWorkspacePlan(
                contextName: finalContextName,
                contextDescription: contextDescription,
                tags: tags,
                peers: peers,
                actions: actions,
                sideNotes: sideNotes,
                rationale: rationale
            ))
    }

    // MARK: - Message helper

    func assistantMessage(from turn: AITurnResult) -> AIMessage? {
        let text = turn.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = (text?.isEmpty == false)
        let toolCalls = turn.toolCalls.isEmpty ? nil : turn.toolCalls
        guard hasText || toolCalls != nil else { return nil }
        return AIMessage(
            role: .assistant,
            content: hasText ? .text(text!) : nil,
            toolCalls: toolCalls ?? []
        )
    }
}
