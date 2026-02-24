import Foundation
import KeepTalkingSDK

enum InteractiveCommand {
    case quit
    case stats
    case p2pTrial
    case newContext
    case join(String)
    case send(String)
    case trust(String)

    static func parse(_ rawLine: String) -> InteractiveCommand? {
        let text = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        if text == "/quit" || text == "/exit" {
            return .quit
        }
        if text == "/stats" {
            return .stats
        }
        if text == "/p2p" || text == "/p2p-trial" {
            return .p2pTrial
        }
        if text == "/new" {
            return .newContext
        }
        if text.hasPrefix("/join") {
            let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let context = parts.count > 1 ? String(parts[1]) : ""
            return .join(context)
        }
        if text.hasPrefix("/trust") {
            let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let node = parts.count > 1 ? String(parts[1]) : ""
            return .trust(node)
        }
        return .send(text)
    }
}

@main
struct KeepTalkingApp {
    static func main() async {
        do {
            let cliConfig = try CliConfig.parse()
            let localStore: any KeepTalkingLocalStore
            if let databaseURL = cliConfig.databaseURL {
                localStore = try KeepTalkingModelStore(databaseURL: databaseURL)
            } else {
                localStore = KeepTalkingClient.makeDefaultLocalStore()
            }

            var currentConfig = cliConfig.sdkConfig
            var client = KeepTalkingClient(
                config: currentConfig,
                localStore: localStore
            )
            var activeContext = KeepTalkingContext(id: currentConfig.contextID)

            func bindCallbacks(to client: KeepTalkingClient) {
                client.onLog = { line in
                    print(line)
                }
                client.onMessage = { (message: KeepTalkingContextMessage) in
                    let senderLabel: String
                    switch message.sender {
                    case .node(let node):
                        senderLabel = node.uuidString.lowercased()
                    case .autonomous(let name):
                        senderLabel = name
                    }
                    print("[\(senderLabel)] \(message.content)")
                }
                client.onRawMessage = { (raw: String) in
                    print("[remote/raw] \(raw)")
                }
            }

            func printRuntimeConfig(_ config: KeepTalkingConfig) {
                print("Connecting to \(config.signalURL.absoluteString)")
                print(
                    "Session=\(config.session) Node=\(config.node.uuidString.lowercased()) Context=\(config.contextID.uuidString.lowercased())"
                )
                print(
                    "Channels: chat=\(config.chatChannelLabel) action_call=\(config.actionCallChannelLabel)"
                )
                print(
                    "P2P upgrade timeout=\(Int(config.p2pAttemptTimeoutSeconds))s stun=\(config.p2pStunServers.joined(separator: ","))"
                )
                if let peer = config.p2pPreferredRemoteID {
                    print("P2P preferred peer=\(peer)")
                }
                if let databaseURL = cliConfig.databaseURL {
                    print("DB=\(databaseURL.path)")
                }
            }

            bindCallbacks(to: client)
            printRuntimeConfig(currentConfig)
            try await client.connect()

            if let oneShot = cliConfig.singleMessage {
                try await client.send(oneShot, in: activeContext)
                print("[you] \(oneShot)")
                client.disconnect()
                return
            }

            print(
                "Connected. Commands: /new, /join <context-id>, /trust <node-id>, /p2p, /stats, /quit."
            )
            while let line = readLine(strippingNewline: true) {
                guard let command = InteractiveCommand.parse(line) else {
                    continue
                }
                switch command {
                case .quit:
                    client.disconnect()
                    return
                case .stats:
                    let stats = client.runtimeStats()
                    print(
                        "Stats: route=\(stats.route ?? "unknown") sent=\(stats.sent) recv=\(stats.received) outbound=\(stats.outboundLabel ?? "nil") state=\(stats.outboundState.map(String.init) ?? "nil") inbound=\(stats.inboundLabel ?? "nil") inboundState=\(stats.inboundState.map(String.init) ?? "nil") retained=\(stats.retainedChannels)"
                    )
                case .p2pTrial:
                    client.requestP2PTrial()
                    print("[local] requested p2p trial")
                case .newContext:
                    let nextContextID = UUID()
                    let previousConfig = currentConfig
                    client.disconnect()

                    let candidateConfig = currentConfig.withContextID(
                        nextContextID
                    )
                    let candidateClient = KeepTalkingClient(
                        config: candidateConfig,
                        localStore: localStore
                    )
                    bindCallbacks(to: candidateClient)

                    do {
                        try await candidateClient.connect()
                        currentConfig = candidateConfig
                        activeContext = KeepTalkingContext(id: nextContextID)
                        client = candidateClient
                        print(
                            "[local] created and joined context=\(nextContextID.uuidString.lowercased())"
                        )
                        print(
                            "[local] channels chat=\(currentConfig.chatChannelLabel) action_call=\(currentConfig.actionCallChannelLabel)"
                        )
                    } catch {
                        candidateClient.disconnect()
                        fputs(
                            "Failed to create/join new context: \(error.localizedDescription)\n",
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
                            activeContext = KeepTalkingContext(
                                id: previousConfig.contextID
                            )
                            client = fallbackClient
                            print(
                                "[local] restored context=\(previousConfig.contextID.uuidString.lowercased())"
                            )
                        } catch {
                            fputs(
                                "Failed to restore previous context: \(error.localizedDescription)\n",
                                stderr
                            )
                            return
                        }
                    }
                case .join(let contextIDRaw):
                    let trimmedContextID = contextIDRaw.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard !trimmedContextID.isEmpty else {
                        print("Usage: /join <context-uuid>")
                        continue
                    }
                    guard let nextContextID = UUID(uuidString: trimmedContextID)
                    else {
                        print("Invalid context UUID: \(trimmedContextID)")
                        continue
                    }

                    let previousConfig = currentConfig
                    client.disconnect()

                    let candidateConfig = currentConfig.withContextID(
                        nextContextID
                    )
                    let candidateClient = KeepTalkingClient(
                        config: candidateConfig,
                        localStore: localStore
                    )
                    bindCallbacks(to: candidateClient)

                    do {
                        try await candidateClient.connect()
                        currentConfig = candidateConfig
                        activeContext = KeepTalkingContext(id: nextContextID)
                        client = candidateClient
                        print(
                            "[local] joined context=\(nextContextID.uuidString.lowercased())"
                        )
                        print(
                            "[local] channels chat=\(currentConfig.chatChannelLabel) action_call=\(currentConfig.actionCallChannelLabel)"
                        )
                    } catch {
                        candidateClient.disconnect()
                        fputs(
                            "Failed to join context: \(error.localizedDescription)\n",
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
                            activeContext = KeepTalkingContext(
                                id: previousConfig.contextID
                            )
                            client = fallbackClient
                            print(
                                "[local] restored context=\(previousConfig.contextID.uuidString.lowercased())"
                            )
                        } catch {
                            fputs(
                                "Failed to restore previous context: \(error.localizedDescription)\n",
                                stderr
                            )
                            return
                        }
                    }
                case .send(let text):
                    do {
                        try await client.send(text, in: activeContext)
                        print("[you] \(text)")
                    } catch {
                        fputs("Send failed: \(error.localizedDescription)\n", stderr)
                    }
                case .trust(let nodeID):
                    let trimmedNodeID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedNodeID.isEmpty {
                        print("Usage: /trust <node-uuid>")
                    } else if let trustedNodeID = UUID(uuidString: trimmedNodeID) {
                        do {
                            try await client.trust(node: trustedNodeID)
                            print(
                                "[local] trusted node=\(trustedNodeID.uuidString.lowercased())"
                            )
                        } catch {
                            fputs(
                                "Trust failed: \(error.localizedDescription)\n",
                                stderr
                            )
                        }
                    } else {
                        print("Invalid node UUID: \(trimmedNodeID)")
                    }
                }
            }

            client.disconnect()
        } catch {
            if let data = "Error: \(error.localizedDescription)\n\n\(keepTalkingUsage)\n".data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
            Foundation.exit(1)
        }
    }
}
