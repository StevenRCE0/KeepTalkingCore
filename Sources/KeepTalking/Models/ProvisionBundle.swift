//
//  ProvisionBundle.swift
//  KeepTalking
//

import Foundation

// MARK: - Policy

/// Policy flags that can be attached to any provisioned field or provider.
/// An absent flag means the stricter default applies.
public nonisolated enum ProvisionPolicy: String, Codable, Sendable, CaseIterable {
    /// The user may edit or override this value after provisioning.
    /// When absent the field is read-only in the UI.
    case userConfigurable

    /// This value persists across SelfNode identity switches.
    /// When absent the value is scoped to the identity active at install time.
    case availableInOtherProfiles
}

// MARK: - Generic field wrapper

/// A provisioned value paired with its policy set.
/// `nil` at the bundle level means "this profile does not configure this field."
public nonisolated struct ProvisionedValue<T: Codable & Sendable>: Codable, Sendable {
    public var value: T
    public var policies: [ProvisionPolicy]

    public init(_ value: T, policies: [ProvisionPolicy] = []) {
        self.value = value
        self.policies = policies
    }

    public var isUserConfigurable: Bool { policies.contains(.userConfigurable) }
    public var isAvailableInOtherNodes: Bool { policies.contains(.availableInOtherProfiles) }
}

// MARK: - Provider entry

public nonisolated struct ProvisionedProvider: Codable, Sendable {
    public var kind: String  // LLMProviderKind.rawValue
    public var displayName: String
    public var apiKey: String?
    public var baseURL: String?
    public var webSearchEnabled: Bool?
    /// Per-provider policy. Defaults to locked + identity-scoped when empty.
    public var policies: [ProvisionPolicy]

    public init(
        kind: String,
        displayName: String,
        apiKey: String? = nil,
        baseURL: String? = nil,
        webSearchEnabled: Bool? = nil,
        policies: [ProvisionPolicy] = []
    ) {
        self.kind = kind
        self.displayName = displayName
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.webSearchEnabled = webSearchEnabled
        self.policies = policies
    }

    /// Whether the user may edit this provider's settings after provisioning.
    /// Absent policy → locked (matches the "defaults to locked when empty" rule).
    public var isUserConfigurable: Bool { policies.contains(.userConfigurable) }
}

// MARK: - Role assignments

/// The agent roles a profile can assign a provider to. The provisioning-facing
/// name for the voice/streaming role is `audioInteraction`; it bridges to the
/// app's `AgentRole.realtime` when applied.
public nonisolated enum ProvisionAgentRole: String, Codable, Sendable, CaseIterable {
    case main
    case act
    case audioInteraction
}

/// What a role is assigned to: a provider (by `displayName`) plus an optional
/// model override. Encodes as `{"provider": …, "model": …}`; `model` nil uses
/// the provider's default model.
public nonisolated struct ProvisionedRoleTarget: Codable, Sendable {
    public var provider: String
    public var model: String?

    public init(provider: String, model: String? = nil) {
        self.provider = provider
        self.model = model
    }
}

/// Enum-indexed role → target map. Encodes to a JSON object keyed by role name
/// (`{"main": {…}, "act": {…}, "audioInteraction": {…}}`); a nil field means
/// the profile does not assign that role.
public nonisolated struct ProvisionedRoleAssignments: Codable, Sendable {
    public var main: ProvisionedRoleTarget?
    public var act: ProvisionedRoleTarget?
    public var audioInteraction: ProvisionedRoleTarget?

    public init(
        main: ProvisionedRoleTarget? = nil,
        act: ProvisionedRoleTarget? = nil,
        audioInteraction: ProvisionedRoleTarget? = nil
    ) {
        self.main = main
        self.act = act
        self.audioInteraction = audioInteraction
    }

    /// Enum-indexed access to the per-role target.
    public subscript(role: ProvisionAgentRole) -> ProvisionedRoleTarget? {
        get {
            switch role {
                case .main: return main
                case .act: return act
                case .audioInteraction: return audioInteraction
            }
        }
        set {
            switch role {
                case .main: main = newValue
                case .act: act = newValue
                case .audioInteraction: audioInteraction = newValue
            }
        }
    }

    public var isEmpty: Bool { main == nil && act == nil && audioInteraction == nil }
}

// MARK: - Standalone web search

/// Global standalone web search configuration (mirrors `WebSearchSettings`).
public nonisolated struct ProvisionedWebSearch: Codable, Sendable {
    public var kind: String  // StandaloneWebSearchConfiguration.Kind.rawValue
    public var apiKey: String?
    public var isEnabled: Bool

    public init(kind: String, apiKey: String? = nil, isEnabled: Bool = false) {
        self.kind = kind
        self.apiKey = apiKey
        self.isEnabled = isEnabled
    }
}

// MARK: - Security

public nonisolated enum ProvisionSecurity: String, Codable, Sendable {
    /// Plain JSON — API keys stored in clear text. Treat the file as a secret.
    case none = "none"
    /// Future: payload encrypted, decryption requires SFU/PassKV authentication.
    case sfuBound = "sfuBound"
}

// MARK: - Bundle

/// Portable provisioning payload for KeepTalking.
///
/// Each field is `ProvisionedValue<X>?` — nil means this profile does not
/// configure that field (leave whatever the device already has). A non-nil
/// field's `.policies` governs whether the user can edit it and whether it
/// survives SelfNode identity switches.
///
/// Identity establishment (node keypair, PassKV trust relations) is out of
/// scope — the node registers with PassKV separately after provisioning.
///
/// Transport: JSON → base64url → `ktprovision://import?payload=<value>`
/// or exported as a `.ktprovision` file (raw JSON or the packed form).
public nonisolated struct KeepTalkingProvisionBundle: Codable, Sendable, Identifiable {
    /// Stable identity for `sheet(item:)` — derived from bundle contents.
    public var id: String {
        (try? KeepTalkingProvisionEncoder().encodePayload(self)) ?? "\(version)"
    }
    public var version: Int = 1
    public var security: ProvisionSecurity = .none

    // MARK: Topology

    public var passKVServerURL: ProvisionedValue<String>?
    public var sfuHost: ProvisionedValue<String>?
    public var sfuPort: ProvisionedValue<Int>?

    // MARK: AI

    /// Providers to install. Existing providers with the same `displayName`
    /// are updated in-place; others are inserted.
    public var providers: ProvisionedValue<[ProvisionedProvider]>?

    /// Enum-indexed role → provider `displayName` assignments. Re-linked by
    /// name after providers are installed, so UUIDs are not required.
    public var roleAssignments: ProvisionedValue<ProvisionedRoleAssignments>?

    /// Global standalone web search backend (independent of any provider).
    public var webSearch: ProvisionedValue<ProvisionedWebSearch>?

    // MARK: Preferences

    public var voiceWakeKeyword: ProvisionedValue<String>?
    public var responseLanguages: ProvisionedValue<[String]>?
    public var maxConnectedContexts: ProvisionedValue<Int>?
    public var attachmentSyncLookbackDays: ProvisionedValue<Int>?
    /// Opt-in for anonymous usage analytics (FeedbackKit user journeys).
    /// Mirrors the app's `SelfNode.analyticsEnabled`.
    public var analyticsEnabled: ProvisionedValue<Bool>?

    public init(
        version: Int = 1,
        security: ProvisionSecurity = .none,
        passKVServerURL: ProvisionedValue<String>? = nil,
        sfuHost: ProvisionedValue<String>? = nil,
        sfuPort: ProvisionedValue<Int>? = nil,
        providers: ProvisionedValue<[ProvisionedProvider]>? = nil,
        roleAssignments: ProvisionedValue<ProvisionedRoleAssignments>? = nil,
        webSearch: ProvisionedValue<ProvisionedWebSearch>? = nil,
        voiceWakeKeyword: ProvisionedValue<String>? = nil,
        responseLanguages: ProvisionedValue<[String]>? = nil,
        maxConnectedContexts: ProvisionedValue<Int>? = nil,
        attachmentSyncLookbackDays: ProvisionedValue<Int>? = nil,
        analyticsEnabled: ProvisionedValue<Bool>? = nil
    ) {
        self.version = version
        self.security = security
        self.passKVServerURL = passKVServerURL
        self.sfuHost = sfuHost
        self.sfuPort = sfuPort
        self.providers = providers
        self.roleAssignments = roleAssignments
        self.webSearch = webSearch
        self.voiceWakeKeyword = voiceWakeKeyword
        self.responseLanguages = responseLanguages
        self.maxConnectedContexts = maxConnectedContexts
        self.attachmentSyncLookbackDays = attachmentSyncLookbackDays
        self.analyticsEnabled = analyticsEnabled
    }

    // MARK: URL encoding

    /// Builds a `ktprovision://import?payload=…` URL carrying this bundle as a
    /// plain-JSON base64url payload.
    public func provisionURL() throws -> URL {
        var components = URLComponents()
        components.scheme = "ktprovision"
        components.host = "import"
        components.queryItems = [
            URLQueryItem(
                name: "payload",
                value: try KeepTalkingProvisionEncoder().encodePayload(self)
            )
        ]
        guard let url = components.url else { throw CocoaError(.coderInvalidValue) }
        return url
    }
}
