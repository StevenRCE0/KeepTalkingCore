import Foundation
import KeepTalkingSDK

/// The CLI's agent configuration: one connector from the selected provider
/// profile (or the inline `--provider`/`--model`/`--api-key` flags), node-wide
/// main and ACT models from it, and per-conversation overrides set with
/// `/model` for the rest of the session. Every client the CLI builds
/// (including after `/new` and `/join`) resolves through this, so a model
/// switch never reconnects.
final class KeepTalkingCLIAgentSelection: @unchecked Sendable {
    enum Role: String {
        case main
        case act
    }

    let profile: CLIProviderProfile?
    let connector: (any AIConnector)?
    /// Why there is no connector, for `/model` and the startup banner.
    let connectorError: String?
    let nodeMainModel: String?
    let nodeACTModel: String?
    let catalog: KeepTalkingModelCatalog
    /// models.dev provider id for profile lookups; `nil` for a custom endpoint.
    let catalogProviderID: String?

    private let lock = NSLock()
    private var mainOverrides: [UUID: String] = [:]
    private var actOverrides: [UUID: String] = [:]

    init(cliConfig: CliConfig) {
        let profile: CLIProviderProfile?
        var profileError: String?
        do {
            profile = try Self.resolveProfile(cliConfig)
        } catch {
            profile = nil
            profileError = error.localizedDescription
        }
        self.profile = profile
        var connector: (any AIConnector)?
        if let profile {
            do {
                connector = try profile.makeConnector()
            } catch {
                profileError = error.localizedDescription
            }
        }
        self.connector = connector
        self.connectorError = profileError
        self.nodeMainModel = profile?.model
        self.nodeACTModel = profile?.actModel
        self.catalog = KeepTalkingModelCatalog(cacheURL: KeepTalkingModelCatalog.defaultCacheURL())
        self.catalogProviderID = profile?.kind.catalogProviderID
    }

    /// The selected profile with the run's flags laid over it; an inline
    /// profile when none is selected but `--model` (or `$KT_MODEL`) is given.
    static func resolveProfile(_ cliConfig: CliConfig) throws -> CLIProviderProfile? {
        let env = ProcessInfo.processInfo.environment
        var profile: CLIProviderProfile
        if let selected = try CLIProviderProfileStore.load().selected(explicitName: cliConfig.profileName) {
            profile = selected
            if let provider = cliConfig.provider { profile.kind = provider }
            if let model = cliConfig.model { profile.model = model }
        } else {
            guard let model = cliConfig.model else { return nil }
            let kind = cliConfig.provider ?? (cliConfig.openAIEndpoint == nil ? .openrouter : .custom)
            profile = CLIProviderProfile(name: "inline", kind: kind, model: model)
            // The CLI always read OPENAI_API_KEY for OpenRouter too.
            if kind == .openrouter, env["OPENROUTER_API_KEY"] == nil, env["OPENAI_API_KEY"] != nil {
                profile.apiKeyEnv = "OPENAI_API_KEY"
            }
        }
        if let actModel = cliConfig.actModel { profile.actModel = actModel }
        if let effort = cliConfig.effort { profile.effort = effort.rawValue }
        if let endpoint = cliConfig.openAIEndpoint { profile.endpoint = endpoint }
        profile.overrideAPIKey = cliConfig.openAIAPIKey
        return profile
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
            act: .init(connector: connector, model: actModel, profile: profile(for: actModel)),
            reasoningEffort: profile?.reasoningEffort,
            responseLanguages: profile?.languages ?? []
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
            print(
                "[model] no provider: \(agentSelection.connectorError ?? "pass --profile <name> or --provider/--model/--api-key")"
            )
        } else if let profile = agentSelection.profile {
            print("[model] provider: \(profile.name) (\(profile.summary))")
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
