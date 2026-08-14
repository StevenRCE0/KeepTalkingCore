//
//  SkillPlanner+Drive.swift
//  KeepTalking
//
//  The planner's model/tool turn loop. Runs the open session until it
//  terminates — `kt_finalize`, `kt_refuse`, or a direct primitive / shortcut /
//  HTTP-MCP action — dispatching each tool call the model makes and persisting
//  accumulated scope back onto the session so `continuePlanning` can resume.
//

import AIProxy
import Foundation
import MCP

extension KeepTalkingSkillPlanner {

    /// Runs the model/tool loop on the open session until it terminates
    /// (finalize, refuse, or a direct action). Loads accumulated state from the
    /// run, then persists it back before returning a `.plan` result so a later
    /// `continuePlanning` builds on it rather than starting fresh.
    ///
    /// Assumes serial use — the host gates new turns on the previous one
    /// completing (the action-creation UI disables its composer while planning).
    func drive(
        onEvent: (@Sendable (KeepTalkingSkillPlannerEvent) async -> String?)?
    ) async throws -> KeepTalkingSkillPlannerResult {
        guard let run else { throw KeepTalkingSkillPlannerError.noActiveSession }
        guard let aiConnector = skillManager.aiConnector else {
            throw SkillManagerError.missingAIConnector
        }
        let bundle = run.bundle
        let tools = run.tools

        var messages = run.messages
        var requiredEnv = run.requiredEnv
        var requiredDirectories = run.requiredDirectories
        var requiredFiles = run.requiredFiles
        var requiredNetworkHosts = run.requiredNetworkHosts
        var grantedNetworkHosts = run.grantedNetworkHosts
        var setupNetworkHosts = run.setupNetworkHosts
        var grantedSetupNetworkHosts = run.grantedSetupNetworkHosts
        var collectedParameters = run.collectedParameters
        var skillName = run.skillName
        var rationale = run.rationale
        var finalized = false

        // Writes the working state back onto the session so the next
        // continuePlanning turn resumes from here. Called on every terminal
        // path that can be continued (a finalized plan, or a refusal the user
        // may argue with).
        func persist() {
            run.messages = messages
            run.requiredEnv = requiredEnv
            run.requiredDirectories = requiredDirectories
            run.requiredFiles = requiredFiles
            run.requiredNetworkHosts = requiredNetworkHosts
            run.grantedNetworkHosts = grantedNetworkHosts
            run.setupNetworkHosts = setupNetworkHosts
            run.grantedSetupNetworkHosts = grantedSetupNetworkHosts
            run.collectedParameters = collectedParameters
            run.skillName = skillName
            run.rationale = rationale
        }

        var nudged = false
        for _ in 0..<Self.maxTurns {
            let turn = try await aiConnector.completeTurn(
                messages: messages,
                tools: tools,
                model: model,
                toolChoice: nil,
                stage: .planning,
                toolExecutor: nil
            )

            if turn.toolCalls.isEmpty {
                // Model stopped calling tools — nudge it once to finalize
                if !finalized && !nudged {
                    nudged = true
                    if let assistantMsg = assistantMessage(from: turn) {
                        messages.append(assistantMsg)
                    }
                    messages.append(
                        .user(
                            "You must call kt_finalize now to complete the analysis. "
                                + "Record any remaining required env/dirs/files/network first, "
                                + "then call kt_finalize with a rationale."
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
                let args = (try? await skillManager.decodeToolArguments(call.argumentsJSON)) ?? [:]
                var result: String

                switch call.name {

                    case Self.readFileTool:
                        let path = string(args["path"]) ?? ""
                        _ = await onEvent?(.readingFile(path: path))
                        do {
                            guard let dir = bundle.directory else {
                                result = "Error: no skill directory set."
                                break
                            }
                            let normalized = await skillManager.normalizedSkillToolArguments(args)
                            result = try await skillManager.executeGetFile(normalized, skillDirectory: dir)
                        } catch {
                            result = "Error: \(error.localizedDescription)"
                        }

                    case Self.requireEnvTool:
                        let name = string(args["name"]) ?? ""
                        if !name.isEmpty && !requiredEnv.contains(name) { requiredEnv.append(name) }
                        if let existing = collectedParameters[name], !existing.isEmpty {
                            // Already supplied earlier this session — don't re-prompt on revise.
                            result = "Already provided earlier: \(existing)"
                            break
                        }
                        let providedValue = await onEvent?(.requiringEnv(name: name))
                        if let value = providedValue, !value.isEmpty {
                            collectedParameters[name] = value
                            result = "Noted. User provided value: \(value)"
                        } else {
                            result = "Noted. User skipped — use built-in defaults."
                        }

                    case Self.requireDirTool:
                        let label = string(args["label"]) ?? ""
                        let purpose = string(args["purpose"]) ?? ""
                        if !label.isEmpty && !requiredDirectories.contains(label) { requiredDirectories.append(label) }
                        if let existing = collectedParameters[label], !existing.isEmpty {
                            result = "Already granted earlier: \(existing)"
                            break
                        }
                        let providedPath = await onEvent?(
                            .requiringDirectory(label: label, purpose: purpose))
                        if let path = providedPath, !path.isEmpty {
                            collectedParameters[label] = path
                            result = "Noted. User selected directory: \(path)"
                        } else {
                            result = "Noted. User skipped — no directory granted."
                        }

                    case Self.requireFileTool:
                        let label = string(args["label"]) ?? ""
                        let purpose = string(args["purpose"]) ?? ""
                        let contentTypes = arrayOfStrings(args["content_types"] ?? .null) ?? []
                        if !label.isEmpty && !requiredFiles.contains(label) { requiredFiles.append(label) }
                        if let existing = collectedParameters[label], !existing.isEmpty {
                            result = "Already granted earlier: \(existing)"
                            break
                        }
                        let providedPath = await onEvent?(
                            .requiringFile(
                                label: label, purpose: purpose, contentTypes: contentTypes))
                        if let path = providedPath, !path.isEmpty {
                            collectedParameters[label] = path
                            result = "Noted. User selected file: \(path)"
                        } else {
                            result = "Noted. User skipped — no file granted."
                        }

                    case Self.requireExecutableTool:
                        let name = string(args["name"]) ?? ""
                        let path = string(args["path"]) ?? ""
                        let purpose = string(args["purpose"]) ?? ""
                        let label = name.isEmpty ? path : name
                        guard path.hasPrefix("/") else {
                            result =
                                "Error: kt_require_executable needs the absolute `path` that kt_probe_command reported."
                            break
                        }
                        // Store the grant exactly like kt_require_file so it flows
                        // to the runtime exec allowlist identically — ScopeResolver
                        // maps a requiredFiles-keyed absolute-path parameter to a
                        // [.read, .execute] resource. The only difference is the
                        // path comes from the probe (Allow/Deny), not a picker.
                        if !label.isEmpty && !requiredFiles.contains(label) {
                            requiredFiles.append(label)
                        }
                        if let existing = collectedParameters[label], !existing.isEmpty {
                            result = "Already granted earlier. The skill may run \(existing)."
                            break
                        }
                        let execGranted = await onEvent?(
                            .requiringExecutable(name: label, path: path, purpose: purpose))
                        if let execGranted, execGranted.lowercased() == "granted" {
                            collectedParameters[label] = path
                            result = "Granted. The skill may run \(label) at \(path) at runtime."
                        } else {
                            result =
                                "User denied — \(label) stays unrunnable. Pick another tool or kt_refuse."
                        }

                    case Self.requireNetworkTool:
                        let host = string(args["host"]) ?? ""
                        let purpose = string(args["purpose"]) ?? ""
                        if !host.isEmpty && !requiredNetworkHosts.contains(host) {
                            requiredNetworkHosts.append(host)
                        }
                        if grantedNetworkHosts.contains(host) {
                            result = "Already granted earlier. The skill may reach \(host)."
                            break
                        }
                        let granted = await onEvent?(.requiringNetwork(host: host, purpose: purpose))
                        if let granted, granted.lowercased() == "granted" {
                            if !grantedNetworkHosts.contains(host) { grantedNetworkHosts.append(host) }
                            result = "Granted. The skill may reach \(host) at runtime."
                        } else {
                            result = "User denied or skipped network access to \(host)."
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

                    #if os(macOS)
                        case Self.probeCommandTool:
                            let name = (string(args["name"]) ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let grantedRoots = collectedParameters.values.filter { $0.hasPrefix("/") }
                            let probe = await probeCommand(name, grantedRoots: Array(grantedRoots))
                            _ = await onEvent?(.probing(summary: "Probe \(name)", detail: probe.summary))
                            result = probe.toolResult

                        case Self.checkPathTool:
                            let path = (string(args["path"]) ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let info = checkPath(path)
                            _ = await onEvent?(.probing(summary: "Check \(path)", detail: info.summary))
                            result = info.toolResult

                        case Self.shellTool:
                            // The planner's general shell — used every turn to both
                            // inspect the machine AND provision the env (installs,
                            // venvs). Unsandboxed login shell. When a command reaches
                            // the network, the model lists the hosts in `network_hosts`
                            // and we take SETUP-time consent per host (separate from
                            // runtime network) BEFORE running; a denied host blocks the
                            // run — the user didn't consent to reaching it during setup.
                            let command = (string(args["command"]) ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let purpose = string(args["purpose"]) ?? ""
                            let cwd = string(args["cwd"])
                            let hosts =
                                (arrayOfStrings(args["network_hosts"] ?? .null) ?? [])
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            guard !command.isEmpty else {
                                result = "Error: kt_shell needs a non-empty `command`."
                                break
                            }
                            var deniedSetupHost: String?
                            for host in hosts {
                                if !setupNetworkHosts.contains(host) { setupNetworkHosts.append(host) }
                                if grantedSetupNetworkHosts.contains(host) { continue }
                                let granted = await onEvent?(
                                    .requiringSetupNetwork(host: host, purpose: purpose))
                                if let granted, granted.lowercased() == "granted" {
                                    grantedSetupNetworkHosts.append(host)
                                } else {
                                    deniedSetupHost = host
                                    break
                                }
                            }
                            if let deniedSetupHost {
                                result =
                                    "User denied setup network access to \(deniedSetupHost). The "
                                    + "command was NOT run. Try an approach that doesn't reach "
                                    + "\(deniedSetupHost), or decline with kt_refuse (category \"blocked\")."
                                break
                            }
                            // Default cwd to a granted directory when the agent didn't
                            // pass one, so installs land in the project the user pointed at.
                            let grantedDir =
                                requiredDirectories
                                .compactMap { collectedParameters[$0] }
                                .first(where: { $0.hasPrefix("/") })
                            let outcome = await runShellCommand(command: command, cwd: cwd ?? grantedDir)
                            _ = await onEvent?(.probing(summary: "shell: \(command)", detail: outcome.summary))
                            result = outcome.toolResult
                    #endif

                    case Self.createShortcutTool:
                        let shortcutName = string(args["shortcut_name"]) ?? ""
                        let desc = string(args["description"]) ?? shortcutName
                        _ = await onEvent?(.creatingShortcut(name: shortcutName))
                        guard !shortcutName.isEmpty else {
                            result = "Error: shortcut_name is required."
                            break
                        }
                        return .directAction(
                            KeepTalkingPrimitiveBundle(
                                name: shortcutName,
                                indexDescription: desc,
                                action: .runMacOSShortcut,
                                shortcutName: shortcutName
                            ))

                    case Self.createPrimitiveTool:
                        let kindStr = string(args["action_kind"]) ?? ""
                        let desc = string(args["description"]) ?? kindStr
                        _ = await onEvent?(.creatingPrimitive(kind: kindStr))
                        guard let kind = KeepTalkingPrimitiveActionKind(rawValue: kindStr) else {
                            result =
                                "Error: unknown action_kind '\(kindStr)'. Valid: \(KeepTalkingPrimitiveActionKind.allCases.map(\.rawValue).joined(separator: ", "))"
                            break
                        }
                        let name = string(args["name"]) ?? kindStr
                        let proposedScope: [String: [String]] = {
                            guard case .object(let dict)? = args["scope"] else { return [:] }
                            var out: [String: [String]] = [:]
                            for (key, value) in dict {
                                guard case .array(let entries) = value else { continue }
                                let strings: [String] = entries.compactMap {
                                    if case .string(let s) = $0 {
                                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                        return trimmed.isEmpty ? nil : trimmed
                                    }
                                    return nil
                                }
                                if !strings.isEmpty { out[key] = strings }
                            }
                            return out
                        }()

                        var finalScope: [String: [String]]? =
                            proposedScope.isEmpty ? nil : proposedScope
                        if !kind.scopeSchema.isEmpty {
                            let schemaJSON =
                                Self.renderJSONSchema(.object(kind.scopeSchema)) ?? "{}"
                            let proposalJSON =
                                Self.renderJSONSchema(
                                    .object(
                                        proposedScope.mapValues { entries in
                                            .array(entries.map { .string($0) })
                                        })) ?? "{}"
                            let editedJSON = await onEvent?(
                                .proposingPrimitiveScope(
                                    kind: kind.rawValue,
                                    proposedScopeJSON: proposalJSON,
                                    schemaJSON: schemaJSON
                                ))
                            if let editedJSON,
                                let data = editedJSON.data(using: .utf8),
                                let parsed = try? JSONSerialization.jsonObject(with: data)
                                    as? [String: Any]
                            {
                                var resolved: [String: [String]] = [:]
                                for (key, value) in parsed {
                                    guard let arr = value as? [Any] else { continue }
                                    let strings = arr.compactMap { entry -> String? in
                                        guard let s = entry as? String else { return nil }
                                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                        return t.isEmpty ? nil : t
                                    }
                                    if !strings.isEmpty { resolved[key] = strings }
                                }
                                finalScope = resolved.isEmpty ? nil : resolved
                            }
                        }

                        return .directAction(
                            KeepTalkingPrimitiveBundle(
                                name: name,
                                indexDescription: desc,
                                action: kind,
                                scope: finalScope
                            ))

                    case Self.requireHTTPURLTool:
                        let serviceName = string(args["service_name"]) ?? ""
                        let providedURL = await onEvent?(.requiringHTTPURL(serviceName: serviceName))
                        if let provided = providedURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                            !provided.isEmpty
                        {
                            // The agent often stops here and calls kt_finalize
                            // without ever creating the MCP. Spell out the
                            // required follow-up unambiguously.
                            result =
                                "User provided URL: \(provided). MANDATORY NEXT STEP: call kt_create_http_mcp now with url=\"\(provided)\" and a name + description. Do NOT call kt_finalize before kt_create_http_mcp — the action is not created until you do."
                        } else {
                            result =
                                "User did not provide a URL. Stop and call kt_finalize without creating an HTTP MCP."
                        }

                    case Self.createHTTPMCPTool:
                        let urlStr = string(args["url"]) ?? ""
                        let mcpName = string(args["name"]) ?? urlStr
                        let desc = string(args["description"]) ?? ""
                        let headers: [String: String] = {
                            guard case .object(let dict)? = args["headers"] else { return [:] }
                            var out: [String: String] = [:]
                            for (k, v) in dict {
                                if case .string(let s) = v { out[k] = s }
                            }
                            return out
                        }()
                        guard let url = URL(string: urlStr), url.scheme?.lowercased().hasPrefix("http") == true
                        else {
                            result = "Error: invalid url '\(urlStr)'."
                            break
                        }
                        _ = await onEvent?(.creatingHTTPMCP(url: url, name: mcpName))
                        return .directHTTPMCP(
                            url: url,
                            name: mcpName.isEmpty ? (url.host ?? urlStr) : mcpName,
                            indexDescription: desc,
                            headers: headers
                        )

                    case Self.askUserTool:
                        let question = string(args["question"]) ?? ""
                        let qContext = string(args["context"]) ?? ""
                        let answer = await onEvent?(
                            .askingUser(question: question, context: qContext))
                        if let answer, !answer.isEmpty {
                            result = "User answered: \(answer)"
                        } else {
                            result =
                                "User did not answer. If you cannot proceed without this information, call kt_refuse."
                        }

                    case Self.refuseTool:
                        let reason = string(args["reason"]) ?? "Planner declined."
                        let category = KeepTalkingSkillPlannerDeclineKind(
                            rawCategory: string(args["category"]))
                        _ = await onEvent?(.refusing(reason: reason, category: category))
                        // Flush this turn's tool results (the decline included) so
                        // the transcript stays valid — every tool call needs a
                        // matching result — if the user argues back next turn.
                        toolResults.append(.tool("Declined.", toolCallID: call.id))
                        messages.append(contentsOf: toolResults)
                        persist()
                        return .refused(reason: reason, category: category)

                    case Self.finalizeTool:
                        rationale = string(args["rationale"]) ?? ""
                        if let n = string(args["name"]), !n.isEmpty { skillName = n }
                        _ = await onEvent?(.finalizing)
                        finalized = true
                        result = "Done."

                    case KeepTalkingClient.runActionToolFunctionName:
                        if let actAgent {
                            let executions = try await actAgent.execute([call], model)
                            for exec in executions {
                                toolResults.append(contentsOf: exec.messages)
                            }
                            continue
                        }
                        result = "{\"ok\":false,\"error\":\"act_not_configured\"}"

                    default:
                        result = "Unknown tool: \(call.name)"
                }

                toolResults.append(.tool(result, toolCallID: call.id))
            }

            messages.append(contentsOf: toolResults)
            if finalized { break }
        }

        guard finalized else { throw KeepTalkingSkillPlannerError.planNotFinalized }

        // Persist the (possibly revised) session state so a later
        // continuePlanning resumes from here instead of re-deriving it.
        persist()

        // The plan is the skill's SANDBOX RESOURCE — its scope (env/dirs/files/
        // network) and collected parameters. No per-operation command list: skills
        // execute via kt_shell, and the seatbelt boundary comes from this scope.
        var planResult = KTSkillCommandPlan(
            skillActionID: run.skillActionID,
            skillName: skillName,
            rationale: rationale ?? "",
            requiredEnv: requiredEnv,
            requiredDirectories: requiredDirectories,
            requiredFiles: requiredFiles,
            requiredNetworkHosts: requiredNetworkHosts,
            grantedNetworkHosts: grantedNetworkHosts,
            setupNetworkHosts: setupNetworkHosts,
            grantedSetupNetworkHosts: grantedSetupNetworkHosts
        )
        if !collectedParameters.isEmpty { planResult.collectedParameters = collectedParameters }
        return .plan(planResult)
    }
}
