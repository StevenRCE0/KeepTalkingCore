import Foundation
import KeepTalkingSDK

final class KeepTalkingCLIController {
    let cliConfig: CliConfig
    let localStore: any KeepTalkingLocalStore
    /// The process-wide transport every context's client attaches to.
    /// Switching contexts swaps clients; the transport stays up.
    let transport: KeepTalkingTransport

    var currentConfig: KeepTalkingConfig
    var client: KeepTalkingClient
    var activeContext: KeepTalkingContext
    let agentSelection: KeepTalkingCLIAgentSelection

    init(cliConfig: CliConfig, localStore: any KeepTalkingLocalStore) {
        self.cliConfig = cliConfig
        self.localStore = localStore
        self.transport = Self.makeTransport(cliConfig)
        self.currentConfig = cliConfig.sdkConfig
        self.agentSelection = KeepTalkingCLIAgentSelection(cliConfig: cliConfig)
        self.client = KeepTalkingClient(
            config: cliConfig.sdkConfig,
            transport: transport,
            localStore: localStore
        )
        self.activeContext = KeepTalkingContext(id: cliConfig.sdkConfig.contextID)
    }

    private static func makeTransport(_ cliConfig: CliConfig) -> KeepTalkingTransport {
        #if canImport(IrohLib)
        guard let relayURL = cliConfig.relayURL else { return .unavailable }
        return .iroh(
            KeepTalkingIrohTransportHost(
                configuration: .init(relayURL: relayURL, sfuEndpointID: cliConfig.sfuEndpointID)
            )
        )
        #else
        return .unavailable
        #endif
    }

    static func writeStderr(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    static func main() async {
        do {
            let cliConfig = try CliConfig.parse()
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
        // Profiles (tools, attachments, window, efforts) come from models.dev;
        // refreshed at most daily, and /ai works without them.
        Task { [catalog = agentSelection.catalog] in _ = try? await catalog.refresh() }
        if agentSelection.configuration(for: activeContext.id ?? currentConfig.contextID) == nil {
            print(
                "[ai] not configured: provide OPENAI_API_KEY/--openai-api-key and --model/KT_MODEL (or /model <id> per context)."
            )
        }

        try await runInteractiveLoop()
    }

    func bindCallbacks(to targetClient: KeepTalkingClient) {
        installAgentConfigurationProvider(on: targetClient)
        installMCPHTTPAuthHandler(on: targetClient)
        installACPAuthHandler(on: targetClient)

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

        targetClient.log.observe { line in
            print(line)
        }
        targetClient.envelopes.observe { envelope in
            if let message = envelope.message {
                print(renderMessage(message))
            }
        }
    }

    func printRuntimeConfig(_ config: KeepTalkingConfig) {
        if let relayURL = cliConfig.relayURL {
            print("Transport: iroh via \(relayURL)\(cliConfig.sfuEndpointID.map { ", SFU \($0.prefix(10))" } ?? "")")
        } else {
            print("Transport: none (no --relay); local commands only")
        }
        print(
            "Node=\(config.node.uuidString.lowercased()) Context=\(config.contextID.uuidString.lowercased())"
        )
        if let databaseURL = cliConfig.databaseURL {
            print("DB=\(databaseURL.path)")
        }
        if let openAIEndpoint = cliConfig.openAIEndpoint {
            print("OpenAI endpoint=\(openAIEndpoint)")
        }
    }

    func printConnectedBanner() {
        print(
            "Connected. Commands: /new, /join <context-id>, /trust <node-id> [all|context|<context-id>], /lure <node-id> <pubkey>, /actions list, /actions grant <node-id> <action-id> [context|all], /mcp add http <name> <url> [--header KEY=VALUE ...] [description], /mcp add stdio <name> [--env KEY=VALUE ...] -- <command> [args...], /mcp list, /mcp remove <action-id>, /skill add directory <name> <path> [description], /skill list, /skill remove <action-id>, /stats, /quit, /ai <message>, /model [act] [<id>|reset]."
        )
    }
}
