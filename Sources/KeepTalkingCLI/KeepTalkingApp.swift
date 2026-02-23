import Foundation
import KeepTalkingSDK

enum InteractiveCommand {
    case quit
    case showPeer
    case stats
    case setPeer(String?)
    case send(String)

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

        if text.hasPrefix("/peer") {
            let parts = text.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else {
                return .showPeer
            }

            let requested = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = requested.lowercased()
            if requested.isEmpty || normalized == "all" || normalized == "*" || normalized == "none" {
                return .setPeer(nil)
            }
            return .setPeer(requested)
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
            let client = KeepTalkingClient(config: config)
            client.onLog = { line in
                print(line)
            }
            client.onMessage = { message in
                print("[\(message.from)] \(message.text)")
            }
            client.onRawMessage = { raw in
                print("[remote/raw] \(raw)")
            }

            print("Connecting to \(config.signalURL.absoluteString)")
            print("Session=\(config.session) ID=\(config.participantID) Channel=\(config.channel)")
            try await client.connect()

            if let oneShot = cliConfig.singleMessage {
                try client.send(text: oneShot, to: nil)
                print("[you] \(oneShot)")
                client.disconnect()
                return
            }

            print("Connected. Type text and press Enter. Use /peer <id> to target, /peer all to broadcast, /quit to exit.")

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let stdinQueue = DispatchQueue(label: "KeepTalking.stdin")
                stdinQueue.async {
                    var targetPeer: String?
                    while let line = readLine(strippingNewline: true) {
                        guard let command = InteractiveCommand.parse(line) else {
                            continue
                        }

                        switch command {
                        case .quit:
                            continuation.resume(returning: ())
                            return
                        case .showPeer:
                            if let targetPeer {
                                print("Current target peer: \(targetPeer)")
                            } else {
                                print("Current target peer: broadcast")
                            }
                        case .stats:
                            let stats = client.runtimeStats()
                            print(
                                "Stats: sent=\(stats.sent) recv=\(stats.received) outbound=\(stats.outboundLabel ?? "nil") state=\(stats.outboundState.map(String.init) ?? "nil") inbound=\(stats.inboundLabel ?? "nil") inboundState=\(stats.inboundState.map(String.init) ?? "nil") retained=\(stats.retainedChannels)"
                            )
                        case let .setPeer(peer):
                            targetPeer = peer
                            if let peer {
                                print("Target peer set to \(peer).")
                            } else {
                                print("Target peer cleared (broadcast).")
                            }
                        case let .send(text):
                            do {
                                print("Sending \(text.utf8.count) bytes to \(targetPeer ?? "all")...")
                                try client.send(text: text, to: targetPeer)
                                if let targetPeer {
                                    print("[you->\(targetPeer)] \(text)")
                                } else {
                                    print("[you] \(text)")
                                }
                            } catch {
                                fputs("Send failed: \(error.localizedDescription)\n", stderr)
                            }
                        }
                    }
                    continuation.resume(returning: ())
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
