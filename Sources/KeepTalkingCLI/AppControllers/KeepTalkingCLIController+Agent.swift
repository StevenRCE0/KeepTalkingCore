import Foundation
import KeepTalkingSDK

/// The CLI's agent configuration: one OpenAI-compatible connector from the
/// key/endpoint flags, node-wide main and ACT models from `--model` /
/// `--act-model`, and per-conversation overrides set with `/model` for the
/// rest of the session. Every client the CLI builds (including after `/new`
/// and `/join`) resolves through this, so a model switch never reconnects.
final class KeepTalkingCLIAgentSelection: @unchecked Sendable {
    enum Role: String {
        case main
        case act
    }

    let connector: (any AIConnector)?
    let nodeMainModel: String?
    let nodeACTModel: String?
    let catalog: KeepTalkingModelCatalog
    /// models.dev provider id for profile lookups; `nil` for a custom endpoint.
    let catalogProviderID: String?

    private let lock = NSLock()
    private var mainOverrides: [UUID: String] = [:]
    private var actOverrides: [UUID: String] = [:]

    init(cliConfig: CliConfig) {
        self.connector = try? OpenAIConnector(
            apiKey: cliConfig.openAIAPIKey,
            endpoint: cliConfig.openAIEndpoint,
            backend: .openRouter
        )
        self.nodeMainModel = cliConfig.model
        self.nodeACTModel = cliConfig.actModel
        self.catalog = KeepTalkingModelCatalog(cacheURL: KeepTalkingModelCatalog.defaultCacheURL())
        self.catalogProviderID = cliConfig.openAIEndpoint == nil ? "openrouter" : nil
    }

    func setOverride(_ model: String?, role: Role, contextID: UUID) {
        lock.withLock {
            switch role {
                case .main: mainOverrides[contextID] = model
                case .act: actOverrides[contextID] = model
            }
        }
    }

    /// The model a role runs with in `contextID`, and whether that comes from
    /// a conversation override.
    func model(for role: Role, contextID: UUID) -> (model: String?, isOverride: Bool) {
        lock.withLock {
            switch role {
                case .main:
                    if let model = mainOverrides[contextID] { return (model, true) }
                    return (nodeMainModel, false)
                case .act:
                    if let model = actOverrides[contextID] { return (model, true) }
                    if let model = mainOverrides[contextID], nodeACTModel == nil { return (model, true) }
                    return (nodeACTModel ?? nodeMainModel, false)
            }
        }
    }

    func profile(for model: String) -> AIModelProfile? {
        catalog.profile(forModel: model, providerID: catalogProviderID)
    }

    /// `nil` when there is no connector or no main model — the SDK then
    /// fails the run with `aiNotConfigured`.
    func configuration(for contextID: UUID) -> KeepTalkingAgentConfiguration? {
        guard let connector,
            let mainModel = model(for: .main, contextID: contextID).model
        else { return nil }
        let actModel = model(for: .act, contextID: contextID).model ?? mainModel
        return KeepTalkingAgentConfiguration(
            main: .init(connector: connector, model: mainModel, profile: profile(for: mainModel)),
            act: .init(connector: connector, model: actModel, profile: profile(for: actModel))
        )
    }
}

extension KeepTalkingCLIController {
    func installAgentConfigurationProvider(on targetClient: KeepTalkingClient) {
        let selection = agentSelection
        targetClient.setAgentConfigurationProvider { request in
            selection.configuration(for: request.contextID)
        }
    }

    /// `/model` — show the active conversation's models;
    /// `/model [act] <id>` — override one for this conversation;
    /// `/model [act] reset` — fall back to the node-wide model.
    func handleModelCommand(role: KeepTalkingCLIAgentSelection.Role?, argument: String) {
        let contextID = activeContext.id ?? currentConfig.contextID
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if let role, !trimmed.isEmpty {
            if trimmed == "reset" {
                agentSelection.setOverride(nil, role: role, contextID: contextID)
            } else {
                agentSelection.setOverride(trimmed, role: role, contextID: contextID)
            }
        }
        for role in [KeepTalkingCLIAgentSelection.Role.main, .act] {
            let (model, isOverride) = agentSelection.model(for: role, contextID: contextID)
            guard let model else {
                print("[model] \(role.rawValue): not set — pass --model/KT_MODEL or /model <id>")
                continue
            }
            let source = isOverride ? "this conversation" : "node default"
            print("[model] \(role.rawValue): \(model) (\(source))\(Self.describe(agentSelection.profile(for: model)))")
        }
        if agentSelection.connector == nil {
            print("[model] no API key: provide OPENAI_API_KEY/--openai-api-key to run /ai")
        }
    }

    private static func describe(_ profile: AIModelProfile?) -> String {
        guard let profile else { return "" }
        var parts: [String] = []
        if !profile.supportsToolCalling { parts.append("no tools") }
        if !profile.supportsAttachments { parts.append("no attachments") }
        if let window = profile.contextWindow { parts.append("\(window / 1000)k window") }
        let efforts = profile.selectableEfforts.map(\.rawValue)
        if !efforts.isEmpty { parts.append("effort: \(efforts.joined(separator: "/"))") }
        return parts.isEmpty ? "" : " — " + parts.joined(separator: ", ")
    }
}
