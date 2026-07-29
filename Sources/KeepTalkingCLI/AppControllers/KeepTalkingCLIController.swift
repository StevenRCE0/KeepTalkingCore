import Foundation
import KeepTalkingSDK

final class KeepTalkingCLIController {
    let cliConfig: CliConfig
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

    static func writeStderr(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    static func main() async {
        do {
            let cliConfig = try CliConfig.parse()
            if let sfuJuice = cliConfig.sfuJuiceEndpoint {
                await SFUJuiceCommand.run(cliConfig: cliConfig, endpoint: sfuJuice)
                return  // SFUJuiceCommand exits the process; unreachable
            }
            let localStore = try await makeLocalStore(
                databaseURL: cliConfig.databaseURL)
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

    private static func makeLocalStore(
        databaseURL: URL?
    ) async throws -> any KeepTalkingLocalStore {
        if let databaseURL {
            return try await KeepTalkingModelStore.make(databaseURL: databaseURL)
        }
        return try await KeepTalkingClient.makeDefaultLocalStore()
    }

    private func run() async throws {
        bindCallbacks(to: client)

        if cliConfig.diagnose {
            await runDiagnose()
            return  // runDiagnose() exits the process; this is unreachable
        }
        if let mcpCommand = cliConfig.mcpCommand {
            try await runMCPManagementCommand(mcpCommand)
            return
        }
        if let skillCommand = cliConfig.skillCommand {
            try await runSkillManagementCommand(skillCommand)
            return
        }

        printRuntimeConfig(currentConfig)

        try await client.connect()
        defer { client.disconnect() }

        // Register local action executors explicitly, off the connection path.
        // Forgiving: a failing executor must not abort the session.
        try? await client.registerLocalActionsInExecutors()

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
        installMCPHTTPAuthHandler(on: targetClient)

        let renderMessage: @Sendable (KeepTalkingContextMessage) -> String = {
            message in
            let senderLabel: String
            switch message.sender {
                case .node(let node):
                    senderLabel = node.uuidString.lowercased()
                case .autonomous(let name, _, _):
                    senderLabel = name
            }
            return "[\(senderLabel)] \(message.content)"
        }

        targetClient.onLog = { line in
            print(line)
        }
        targetClient.onEnvelope = { (envelope: KeepTalkingEnvelope) in
            if let message = envelope.message {
                print(renderMessage(message))
            }
        }
        targetClient.onRawMessage = { (raw: String) in
            print("[remote/raw] \(raw)")
        }
    }

    func printRuntimeConfig(_ config: KeepTalkingConfig) {
        if let endpoint = config.sfuEndpoint {
            print("Connecting to KeepTalkingSFU \(endpoint.host):\(endpoint.port)")
        } else {
            print("KeepTalkingSFU endpoint is not configured")
        }
        print(
            "Session=\(config.scopedSessionID) Node=\(config.node.uuidString.lowercased()) Context=\(config.contextID.uuidString.lowercased())"
        )
        print(
            "Channels: signaling=\(config.signalingChannelLabel) chat=\(config.chatChannelLabel) action_call=\(config.actionCallChannelLabel)"
        )
        print("P2P HTTP/2 upgrade timeout=\(Int(config.p2pAttemptTimeoutSeconds))s")
        if let databaseURL = cliConfig.databaseURL {
            print("DB=\(databaseURL.path)")
        }
        if let openAIEndpoint = cliConfig.openAIEndpoint {
            print("OpenAI endpoint=\(openAIEndpoint)")
        }
    }

    func printConnectedBanner() {
        print(
            "Connected. Commands: /new, /join <context-id>, /trust <node-id> [all|context|<context-id>], /lure <node-id> <pubkey>, /actions list, /actions grant <node-id> <action-id> [context|all], /mcp add http <name> <url> [--header KEY=VALUE ...] [description], /mcp add stdio <name> [--env KEY=VALUE ...] -- <command> [args...], /mcp list, /mcp remove <action-id>, /skill add directory <name> <path> [description], /skill list, /skill remove <action-id>, /p2p, /stats, /quit, /ai <message>."
        )
    }
}
