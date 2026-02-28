import Foundation
import KeepTalkingSDK

final class KeepTalkingCLIController {
    private let cliConfig: CliConfig
    let localStore: any KeepTalkingLocalStore

    var currentConfig: KeepTalkingConfig
    var client: KeepTalkingClient
    var activeContext: KeepTalkingContext

    init(cliConfig: CliConfig, localStore: any KeepTalkingLocalStore) {
        self.cliConfig = cliConfig
        self.localStore = localStore
        self.currentConfig = cliConfig.sdkConfig
        self.client = KeepTalkingClient(
            config: cliConfig.sdkConfig,
            openAIAPIKey: cliConfig.openAIAPIKey,
            openAIEndpoint: cliConfig.openAIEndpoint,
            localStore: localStore
        )
        self.activeContext = KeepTalkingContext(id: cliConfig.sdkConfig.contextID)
    }

    static func main() async {
        do {
            let cliConfig = try CliConfig.parse()
            let localStore = try makeLocalStore(databaseURL: cliConfig.databaseURL)
            let controller = KeepTalkingCLIController(
                cliConfig: cliConfig,
                localStore: localStore
            )
            try await controller.run()
        } catch {
            if let data = "Error: \(error.localizedDescription)\n\n\(keepTalkingUsage)\n"
                .data(using: .utf8)
            {
                FileHandle.standardError.write(data)
            }
            Foundation.exit(1)
        }
    }

    private static func makeLocalStore(databaseURL: URL?) throws -> any KeepTalkingLocalStore {
        if let databaseURL {
            return try KeepTalkingModelStore(databaseURL: databaseURL)
        }
        return KeepTalkingClient.makeDefaultLocalStore()
    }

    private func run() async throws {
        bindCallbacks(to: client)

        if let mcpCommand = cliConfig.mcpCommand {
            try await runMCPManagementCommand(mcpCommand)
            return
        }

        printRuntimeConfig(currentConfig)

        try await client.connect()
        defer { client.disconnect() }

        if let oneShot = cliConfig.singleMessage {
            try await client.send(oneShot, in: activeContext)
            print("[you] \(oneShot)")
            return
        }

        printConnectedBanner()
        if !client.aiEnabled {
            print(
                "[ai] no immediate env/flag key configured; /ai can still work with node-local AI settings."
            )
        }

        try await runInteractiveLoop()
    }

    func bindCallbacks(to targetClient: KeepTalkingClient) {
        let renderMessage: @Sendable (KeepTalkingContextMessage) -> String = {
            message in
            let senderLabel: String
            switch message.sender {
                case .node(let node):
                    senderLabel = node.uuidString.lowercased()
                case .autonomous(let name):
                    senderLabel = name
            }
            return "[\(senderLabel)] \(message.content)"
        }

        targetClient.onLog = { line in
            print(line)
        }
        targetClient.onEnvelope = { (envelope: KeepTalkingP2PEnvelope) in
            switch envelope {
                case .message(let message):
                    print(renderMessage(message))
                case .context(let context):
                    if let latestMessage = context.messages.max(by: {
                        $0.timestamp < $1.timestamp
                    }) {
                        print(renderMessage(latestMessage))
                    }
                default:
                    break
            }
        }
        targetClient.onRawMessage = { (raw: String) in
            print("[remote/raw] \(raw)")
        }
    }

    func printRuntimeConfig(_ config: KeepTalkingConfig) {
        print("Connecting to \(config.signalURL.absoluteString)")
        print(
            "Session=\(config.scopedSessionID) Node=\(config.node.uuidString.lowercased()) Context=\(config.contextID.uuidString.lowercased())"
        )
        print(
            "Channels: signaling=\(config.signalingChannelLabel) chat=\(config.chatChannelLabel) action_call=\(config.actionCallChannelLabel)"
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
        if let openAIEndpoint = cliConfig.openAIEndpoint {
            print("OpenAI endpoint=\(openAIEndpoint)")
        }
    }

    func printConnectedBanner() {
        print(
            "Connected. Commands: /new, /join <context-id>, /trust <node-id> [all|context|<context-id>], /lure <node-id> <pubkey>, /actions list, /actions grant <node-id> <action-id> [context|all], /mcp add http <name> <url> [description], /mcp add stdio <name> [--env KEY=VALUE ...] -- <command> [args...], /mcp list, /mcp remove <action-id>, /p2p, /stats, /quit, /ai <message>."
        )
    }
}
