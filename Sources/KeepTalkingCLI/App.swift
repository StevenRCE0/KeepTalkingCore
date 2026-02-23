import Foundation
import KeepTalkingSDK

enum InteractiveCommand {
    case quit
    case stats
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
            let config = cliConfig.sdkConfig

            let client: KeepTalkingClient
            if let databaseURL = cliConfig.databaseURL {
                client = KeepTalkingClient(
                    config: config,
                    localStore: try KeepTalkingModelStore(databaseURL: databaseURL)
                )
            } else {
                client = KeepTalkingClient(config: config)
            }

            let activeContext = KeepTalkingContext(id: UUID())

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

            print("Connecting to \(config.signalURL.absoluteString)")
            print("Session=\(config.session) Node=\(config.node.uuidString.lowercased()) Channel=\(config.channel)")
            print(
                "P2P upgrade timeout=\(Int(config.p2pAttemptTimeoutSeconds))s stun=\(config.p2pStunServers.joined(separator: ","))"
            )
            if let peer = config.p2pPreferredRemoteID {
                print("P2P preferred peer=\(peer)")
            }
            if let databaseURL = cliConfig.databaseURL {
                print("DB=\(databaseURL.path)")
            }

            try await client.connect()

            if let oneShot = cliConfig.singleMessage {
                try await client.send(oneShot, in: activeContext)
                print("[you] \(oneShot)")
                client.disconnect()
                return
            }

            print("Connected. Type text and press Enter. Use /quit to exit.")
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
                    } else {
                        print("Trust command recorded for node=\(trimmedNodeID).")
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
