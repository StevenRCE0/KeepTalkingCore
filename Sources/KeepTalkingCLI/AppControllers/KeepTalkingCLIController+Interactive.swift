import Foundation
import KeepTalkingSDK

extension KeepTalkingCLIController {
    func runInteractiveLoop() async throws {
        while let line = readLine(strippingNewline: true) {
            guard let command = InteractiveCommand.parse(line) else {
                continue
            }

            let shouldContinue = await handleInteractiveCommand(command)
            if !shouldContinue {
                return
            }
        }
    }

    private func handleInteractiveCommand(_ command: InteractiveCommand) async
        -> Bool
    {
        switch command {
            case .quit:
                return false
            case .stats:
                let stats = client.runtimeStats()
                print(
                    "Stats: route=\(stats.route ?? "unknown") sent=\(stats.sent) recv=\(stats.received) outbound=\(stats.outboundLabel ?? "nil") state=\(stats.outboundState.map(String.init) ?? "nil") inbound=\(stats.inboundLabel ?? "nil") inboundState=\(stats.inboundState.map(String.init) ?? "nil") retained=\(stats.retainedChannels)"
                )
                return true
            case .p2pTrial:
                client.requestP2PTrial()
                print("[local] requested p2p trial")
                return true
            case .newContext:
                let nextContextID = UUID()
                let switched = await switchContext(
                    to: nextContextID,
                    verb: "created and joined",
                    createGroupSecret: true
                )
                guard switched else { return false }
                do {
                    let secret = try await client.ensureGroupChatSecret(
                        for: nextContextID
                    )
                    print(
                        "[local] invite command: /join \(nextContextID.uuidString.lowercased())"
                    )
                    print(
                        "[local] invite key (base64): \(secret.base64EncodedString())"
                    )
                } catch {
                    fputs(
                        "Failed to read new context key: \(error.localizedDescription)\n",
                        stderr
                    )
                }
                return true
            case .join(let contextIDRaw):
                let trimmedContextID = contextIDRaw.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !trimmedContextID.isEmpty else {
                    print("Usage: /join <context-uuid>")
                    return true
                }
                guard let nextContextID = UUID(uuidString: trimmedContextID) else {
                    print("Invalid context UUID: \(trimmedContextID)")
                    return true
                }
                let joinSecret = promptJoinSecret()
                let switched = await switchContext(
                    to: nextContextID,
                    verb: "joined"
                )
                guard switched else { return false }

                if let joinSecret {
                    do {
                        try await client.setGroupChatSecret(
                            joinSecret,
                            for: nextContextID
                        )
                        print(
                            "[local] encryption key saved for context=\(nextContextID.uuidString.lowercased())"
                        )
                    } catch {
                        fputs(
                            "Failed to save encryption key: \(error.localizedDescription)\n",
                            stderr
                        )
                    }
                } else {
                    print(
                        "[local] joined without key. you can still share history, but encrypted messages may not decrypt."
                    )
                }
                return true
            case .send(let text):
                do {
                    try await client.send(text, in: activeContext)
                    print("[you] \(text)")
                } catch {
                    fputs("Send failed: \(error.localizedDescription)\n", stderr)
                }
                return true
            case .trust(let nodeIDRaw, let scopeRaw):
                guard
                    let currentContext = try? await KeepTalkingContext.find(
                        currentConfig.contextID,
                        on: localStore.database
                    )
                else {
                    print("No active context")
                    return true
                }

                let trimmedNodeID = nodeIDRaw.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !trimmedNodeID.isEmpty else {
                    print("Usage: /trust <node-uuid> [all|context|<context-uuid>]")
                    return true
                }
                guard let trustedNodeID = UUID(uuidString: trimmedNodeID) else {
                    print("Invalid node UUID: \(trimmedNodeID)")
                    return true
                }

                let normalizedScope = scopeRaw.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).lowercased()

                let trustScope: KeepTalkingNodeTrustScope
                if normalizedScope.isEmpty || normalizedScope == "all" {
                    trustScope = .allContexts
                } else if normalizedScope == "context"
                    || normalizedScope == "current"
                {
                    trustScope = .context(currentContext)
                } else if UUID(uuidString: normalizedScope) != nil {
                    trustScope = .context(currentContext)
                } else {
                    print(
                        "Invalid trust scope: \(scopeRaw). Use `all`, `context`, or a context UUID."
                    )
                    return true
                }
                do {
                    let localPublicKey = try await client.trust(
                        node: trustedNodeID,
                        scope: trustScope
                    )
                    let scopeLabel: String =
                        switch trustScope {
                            case .allContexts:
                                "all"
                            case .context(let context):
                                "context=\(context.id?.uuidString.lowercased() ?? "missing")"
                        }
                    print(
                        "[local] trusted node=\(trustedNodeID.uuidString.lowercased()) scope=\(scopeLabel)"
                    )
                    print(
                        "[local] share this public key: \(localPublicKey)"
                    )
                    print(
                        "[local] cast this lure on peer: /lure \(currentConfig.node.uuidString.lowercased()) \(localPublicKey)"
                    )
                } catch {
                    fputs("Trust failed: \(error.localizedDescription)\n", stderr)
                }
                return true
            case .lure(let nodeIDRaw, let publicKeyRaw):
                let trimmedNodeID = nodeIDRaw.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let trimmedPublicKey = publicKeyRaw.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !trimmedNodeID.isEmpty, !trimmedPublicKey.isEmpty else {
                    print("Usage: /lure <node-uuid> <pubkey>")
                    return true
                }
                guard let sourceNodeID = UUID(uuidString: trimmedNodeID) else {
                    print("Invalid node UUID: \(trimmedNodeID)")
                    return true
                }
                do {
                    try await client.lure(
                        node: sourceNodeID,
                        publicKey: trimmedPublicKey
                    )
                    print(
                        "[lure] hooked node=\(sourceNodeID.uuidString.lowercased()) pubkey saved for trusted=\(currentConfig.node.uuidString.lowercased())"
                    )
                } catch {
                    fputs("Lure failed: \(error.localizedDescription)\n", stderr)
                }
                return true
            case .actionsList:
                await listActions()
                return true
            case .actionsGrant(let nodeIDRaw, let actionIDRaw, let scopeRaw):
                await grantAction(
                    nodeIDRaw: nodeIDRaw,
                    actionIDRaw: actionIDRaw,
                    scopeRaw: scopeRaw
                )
                return true
            case .ai(let prompt):
                runAI(prompt: prompt)
                return true
            case .mcpList:
                await listMCPActions()
                return true
            case .mcpRemove(let actionIDRaw):
                await removeMCPAction(actionIDRaw: actionIDRaw)
                return true
            case .mcpAddHTTP(let name, let urlRaw, let description):
                await registerHTTPMCPAction(
                    name: name,
                    urlRaw: urlRaw,
                    description: description
                )
                return true
            case .mcpAddSTDIO(let name, let command, let environment):
                await registerStdioMCPAction(
                    name: name,
                    command: command,
                    environment: environment
                )
                return true
        }
    }

    private func switchContext(
        to nextContextID: UUID,
        verb: String,
        createGroupSecret: Bool = false
    ) async -> Bool {
        let previousConfig = currentConfig
        client.disconnect()

        let candidateConfig = currentConfig.withContextID(nextContextID)
        let candidateClient = KeepTalkingClient(
            config: candidateConfig,
            localStore: localStore
        )
        bindCallbacks(to: candidateClient)

        do {
            try await candidateClient.connect()
            if createGroupSecret {
                _ = try await candidateClient.ensureGroupChatSecret(
                    for: nextContextID
                )
            }
            currentConfig = candidateConfig
            activeContext = KeepTalkingContext(id: nextContextID)
            client = candidateClient
            print(
                "[local] \(verb) context=\(nextContextID.uuidString.lowercased())"
            )
            print(
                "[local] channels signaling=\(currentConfig.signalingChannelLabel) chat=\(currentConfig.chatChannelLabel) action_call=\(currentConfig.actionCallChannelLabel)"
            )
            return true
        } catch {
            candidateClient.disconnect()
            fputs(
                "Failed to switch context: \(error.localizedDescription)\n",
                stderr
            )

            let fallbackClient = KeepTalkingClient(
                config: previousConfig,
                localStore: localStore
            )
            bindCallbacks(to: fallbackClient)

            do {
                try await fallbackClient.connect()
                currentConfig = previousConfig
                activeContext = KeepTalkingContext(id: previousConfig.contextID)
                client = fallbackClient
                print(
                    "[local] restored context=\(previousConfig.contextID.uuidString.lowercased())"
                )
                return true
            } catch {
                fputs(
                    "Failed to restore previous context: \(error.localizedDescription)\n",
                    stderr
                )
                return false
            }
        }
    }

    private func promptJoinSecret() -> Data? {
        while true {
            print(
                "Encryption key (base64) for this context [press Enter to skip]: ",
                terminator: ""
            )
            guard let input = readLine(strippingNewline: true) else {
                return nil
            }
            let trimmed = input.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if trimmed.isEmpty {
                return nil
            }
            if let secret = Data(base64Encoded: trimmed), !secret.isEmpty {
                return secret
            }
            print("Invalid base64 key. Try again.")
        }
    }

    private func listActions() async {
        do {
            let actions = try await client.listAvailableActions()
            if actions.isEmpty {
                print("[actions] none")
                return
            }

            print("[actions] total=\(actions.count)")
            for action in actions {
                let owner =
                    action.ownerNodeID?.uuidString.lowercased() ?? "unknown"
                let hosted = action.hostedLocally ? "local" : "remote"
                let remote =
                    action.remoteAuthorisable ? "remote-ok" : "local-only"
                let kind = action.isMCP ? "mcp" : "unknown"
                print(
                    "- id=\(action.actionID.uuidString.lowercased()) type=\(kind) owner=\(owner) host=\(hosted) mode=\(remote) name=\(action.name)"
                )
                if !action.description.isEmpty {
                    print("  desc=\(action.description)")
                }
                if action.grants.isEmpty {
                    print("  grants=none")
                } else {
                    for grant in action.grants {
                        let scope: String
                        switch grant.approvingContext {
                            case .none, .all:
                                scope = "all"
                            case .contexts(let contexts):
                                scope =
                                    "context=\(contexts)"
                        }
                        print(
                            "  grant to=\(grant.toNodeID.uuidString.lowercased()) scope=\(scope)"
                        )
                    }
                }
            }
        } catch {
            fputs(
                "List actions failed: \(error.localizedDescription)\n",
                stderr
            )
        }
    }

    private func grantAction(
        nodeIDRaw: String,
        actionIDRaw: String,
        scopeRaw: String
    ) async {
        let trimmedNodeID = nodeIDRaw.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let trimmedActionID = actionIDRaw.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard let nodeID = UUID(uuidString: trimmedNodeID) else {
            print("Invalid node UUID: \(trimmedNodeID)")
            return
        }
        guard let actionID = UUID(uuidString: trimmedActionID) else {
            print("Invalid action UUID: \(trimmedActionID)")
            return
        }

        let scopeToken = scopeRaw.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        let scope: KeepTalkingActionPermissionScope?
        if scopeToken.isEmpty || scopeToken == "context"
            || scopeToken == "current"
        {
            let contextID = activeContext.id ?? currentConfig.contextID
            scope = .context(KeepTalkingContext(id: contextID))
        } else if scopeToken == "all" {
            scope = .all
        } else {
            print("Invalid scope: \(scopeRaw). Use `context` or `all`.")
            scope = nil
        }
        guard let scope else {
            return
        }

        do {
            try await client.grantActionPermission(
                actionID: actionID,
                toNodeID: nodeID,
                scope: scope
            )
            let scopeLabel: String =
                switch scope {
                    case .all:
                        "all"
                    case .context(let context):
                        "context=\(context.id?.uuidString.lowercased() ?? "nil")"
                }
            print(
                "[local] granted action=\(actionID.uuidString.lowercased()) to=\(nodeID.uuidString.lowercased()) scope=\(scopeLabel)"
            )
        } catch {
            fputs(
                "Grant action failed: \(error.localizedDescription)\n",
                stderr
            )
        }
    }

    private func runAI(prompt: String) {
        let trimmedPrompt = prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedPrompt.isEmpty else {
            print("Usage: /ai <prompt>")
            return
        }

        let client = self.client
        let contextID = activeContext.id ?? currentConfig.contextID
        let context = KeepTalkingContext(id: contextID)

        Task {
            do {
                try await client.send(trimmedPrompt, in: context)
                print("[you] \(trimmedPrompt)")
            } catch {
                fputs(
                    "Failed to send /ai prompt: \(error.localizedDescription)\n",
                    stderr
                )
            }

            do {
                print("[ai] querying...")
                let aiResponse = try await client.runAI(
                    prompt: trimmedPrompt,
                    in: context
                )
                print(aiResponse)
                try await client.send(
                    aiResponse,
                    in: context,
                    sender: KeepTalkingContextMessage.Sender.autonomous(
                        name: "ai"
                    )
                )
            } catch {
                if let clientError = error as? KeepTalkingClientError,
                    case .aiNotConfigured = clientError
                {
                    print(
                        "[ai] disabled: provide OPENAI_API_KEY/--openai-api-key and optionally --openai-endpoint."
                    )
                    return
                }
                fputs(
                    "AI query failed: \(error.localizedDescription)\n",
                    stderr
                )
            }
        }
    }
}
