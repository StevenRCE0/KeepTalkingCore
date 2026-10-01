import Foundation

// MARK: - KeepTalkingAgentConfiguration

/// Everything an agent run needs to know about the models behind it: which
/// connector and model drive the main loop and the ACT sub-agent, what those
/// models can do, and the per-turn knobs the host chose.
///
/// The client holds none of this. A run started by a send carries its
/// configuration in (`enqueueAIPrompt(_:…agent:)`); work the node serves on
/// its own — a peer's delegated action, a KTPP `host.act.request`, a planner's
/// ACT agent, a delegated task — asks the host for one through
/// `KeepTalkingClient.setAgentConfigurationProvider(_:)` at the moment it
/// runs. Switching models therefore never touches the transport.
public struct KeepTalkingAgentConfiguration: Sendable {
    /// One agent role: a connector, the model it should target, and — when
    /// the host knows it — what that model can do.
    public struct Role: Sendable {
        public let connector: any AIConnector
        public let model: String
        /// `nil` keeps the loop's default assumptions (tools, attachments,
        /// fixed history budgets, any effort).
        public let profile: AIModelProfile?

        public init(connector: any AIConnector, model: String, profile: AIModelProfile? = nil) {
            self.connector = connector
            self.model = model
            self.profile = profile
        }
    }

    /// Drives the conversation loop.
    public var main: Role
    /// Drives the ACT sub-agent (`kt_run_action`), skill execution for
    /// incoming action calls, plugin ACT turns, and planners' ACT agents.
    public var act: Role
    /// Requested reasoning effort for the main loop. Snapped onto what the
    /// main model accepts before it is sent.
    public var reasoningEffort: AIReasoning.Effort?
    /// Preferred natural-language output languages. Empty means infer from
    /// the user.
    public var responseLanguages: [String]

    public init(
        main: Role,
        act: Role? = nil,
        reasoningEffort: AIReasoning.Effort? = nil,
        responseLanguages: [String] = []
    ) {
        self.main = main
        self.act = act ?? main
        self.reasoningEffort = reasoningEffort
        self.responseLanguages = responseLanguages.reduce(into: []) { result, language in
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(trimmed) else { return }
            result.append(trimmed)
        }
    }
}

// MARK: - Provider

/// Why the client is asking the host for a configuration. Every case names
/// the context the work belongs to, so a host with per-conversation model
/// choices answers with that conversation's.
public struct KeepTalkingAgentConfigurationRequest: Sendable, Equatable {
    public enum Purpose: Sendable, Equatable {
        /// A main-loop run with no configuration handed in — a delegated task,
        /// or a direct `runAI` call that omitted one.
        case conversation
        /// A peer's call into one of this node's skill actions.
        case delegatedAction(callerNodeID: UUID)
        /// A KTPP plugin's `host.act.request`.
        case pluginACT(callerNodeID: UUID)
        /// A planner's ACT agent launched inside a conversation.
        case skillPlanner
    }

    public let contextID: UUID
    public let purpose: Purpose

    public init(contextID: UUID, purpose: Purpose) {
        self.contextID = contextID
        self.purpose = purpose
    }
}

extension KeepTalkingClient {
    /// Resolves the configuration for work the node runs without one handed
    /// in. Returning `nil` means AI is not configured for that context, and
    /// the work fails with `KeepTalkingClientError.aiNotConfigured`.
    public typealias AgentConfigurationProvider =
        @Sendable (KeepTalkingAgentConfigurationRequest) async -> KeepTalkingAgentConfiguration?

    func resolveAgentConfiguration(
        _ request: KeepTalkingAgentConfigurationRequest
    ) async throws -> KeepTalkingAgentConfiguration {
        guard let provider = agentConfigurationProvider,
            let configuration = await provider(request)
        else {
            throw KeepTalkingClientError.aiNotConfigured
        }
        return configuration
    }
}
