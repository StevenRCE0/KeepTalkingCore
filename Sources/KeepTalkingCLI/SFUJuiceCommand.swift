import Foundation
import KeepTalkingSDK

/// `--sfu-juice host:port` smoke-test loop. Skips the SDK's normal
/// signal-server + WebRTC bring-up and instead runs a minimal stdin↔SFU
/// broadcast harness against a Swift-native KeepTalkingSFU server.
///
/// Usage:
///   KeepTalking --sfu-juice 127.0.0.1:9701 --context <uuid>
///
/// Each stdin line is broadcast to the configured context as opaque bytes;
/// every inbound payload is printed prefixed by sender (placeholder).
enum SFUJuiceCommand {
    static func run(
        cliConfig: CliConfig,
        endpoint: CliConfig.SFUJuiceEndpoint
    ) async {
        let store = makeKeychainStore()
        do {
            let signingKey = try await KeepTalkingSFUSigningKey.loadOrCreate(
                nodeID: cliConfig.sdkConfig.node,
                store: store
            )
            let pubHex = signingKey.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }
                .joined()
            stderr("KeepTalkingSFU lab: node=\(cliConfig.sdkConfig.node.uuidString.lowercased()) pubkey=\(pubHex)")

            let session = KeepTalkingSFUJuiceSession(
                config: cliConfig.sdkConfig,
                sfuHost: endpoint.host,
                sfuPort: endpoint.port,
                signingKey: signingKey
            )
            session.onLog = { msg in stderr("[sfu] \(msg)") }
            session.onPresence = { event in
                switch event {
                    case .snapshot(_, let peers):
                        let names = peers.map { $0.prefix(4).map { String(format: "%02x", $0) }.joined() }
                        stderr(
                            "[presence] roster=[\(names.joined(separator: ","))] (\(peers.count) peer\(peers.count == 1 ? "" : "s"))"
                        )
                    case .joined(_, let pubkey):
                        let short = pubkey.prefix(4).map { String(format: "%02x", $0) }.joined()
                        stderr("[presence] +\(short) joined")
                    case .left(_, let pubkey):
                        let short = pubkey.prefix(4).map { String(format: "%02x", $0) }.joined()
                        stderr("[presence] -\(short) left")
                }
            }
            session.onInbound = { payload in
                // Route to stderr so the test harness sees it even when
                // stdout's fully-buffered-to-pipe mode swallows prints
                // that haven't flushed by the time the process is killed.
                switch payload {
                    case .envelope(let env, _, _):
                        stderr("<-- envelope kind=\(env.kind)")
                    case .opaqueBytes(let data, _, _):
                        if let text = String(data: data, encoding: .utf8) {
                            stderr("<-- \(text)")
                        } else {
                            stderr("<-- \(data.count) opaque bytes")
                        }
                }
            }

            try await session.start()
            stderr("connected. type lines to broadcast, Ctrl-D / Ctrl-C to quit.")

            await readStdinLoop { line in
                stderr("[stdin] read line bytes=\(line.utf8.count)")
                if line.isEmpty { return }
                do {
                    try session.broadcastRawBytes(Data(line.utf8))
                    stderr("[stdin] broadcast sent")
                } catch {
                    stderr("send error: \(error.localizedDescription)")
                }
            }
            stderr("[stdin] loop exited (EOF)")

            session.stop()
            stderr("bye")
            Foundation.exit(0)
        } catch {
            stderr("error: \(error.localizedDescription)")
            Foundation.exit(1)
        }
    }

    // MARK: - Helpers

    private static func makeKeychainStore() -> any KeepTalkingKeychainStore {
        #if canImport(Security)
        return KeepTalkingSecItemKeychainStore.shared
        #else
        return KeepTalkingInMemoryKeychainStore()
        #endif
    }

    private static func readStdinLoop(_ handler: @escaping @Sendable (String) -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                while let line = readLine() {
                    handler(line)
                }
                cont.resume()
            }
        }
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
