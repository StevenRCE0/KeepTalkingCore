import Foundation

/// Per-action HTTP MCP credentials: the resolved request headers (which carry
/// OAuth bearer tokens and any API-key headers) plus the OAuth client secret.
///
/// These are sensitive and live **only** in the keychain via
/// `KeepTalkingMCPCredentialStore` — never in the action's database payload or
/// anything synced to peers. The runtime re-hydrates headers from here at
/// connect time; the OAuth flow reads the client secret here at token exchange.
public struct KeepTalkingMCPCredentials: Codable, Sendable, Equatable {
    /// Static request headers (e.g. a user-entered API key). The OAuth bearer is
    /// NOT stored here — the SDK authorizer injects it from its token storage.
    public var headers: [String: String]
    /// User/config-supplied OAuth client ID, when not coming from app config.
    public var clientID: String?
    /// OAuth confidential-client secret.
    public var clientSecret: String?
    /// Last acquired OAuth access token (cached for cross-launch reuse).
    public var accessToken: String?
    /// Expiry of `accessToken`, if the authorization server reported one.
    public var accessTokenExpiresAt: Date?
    /// Refresh token, used to silently renew without re-prompting.
    public var refreshToken: String?
    /// `redirect_uri` the stored client and tokens were obtained with. A client
    /// registered against one redirect URI cannot be reused with another, so a
    /// change of redirect strategy (see `KeepTalkingMCPBundle.requiresRedirectProxy`)
    /// is detected by comparing against this. Optional: credentials written
    /// before the field existed simply read as "unknown" and are reused.
    public var redirectURI: String?

    public init(
        headers: [String: String] = [:],
        clientID: String? = nil,
        clientSecret: String? = nil,
        accessToken: String? = nil,
        accessTokenExpiresAt: Date? = nil,
        refreshToken: String? = nil,
        redirectURI: String? = nil
    ) {
        self.headers = headers
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.redirectURI = redirectURI
    }

    /// True when there is nothing worth persisting — the store deletes the
    /// keychain entry in that case rather than writing an empty blob.
    public var isEmpty: Bool {
        headers.isEmpty
            && (clientID?.isEmpty ?? true)
            && (clientSecret?.isEmpty ?? true)
            && (accessToken?.isEmpty ?? true)
            && (refreshToken?.isEmpty ?? true)
            && accessTokenExpiresAt == nil
    }
}

/// Keychain-backed store for `KeepTalkingMCPCredentials`, keyed by action ID.
///
/// This is the single seam through which the SDK persists and reads MCP
/// credentials. It talks only to the `KeepTalkingKeychainStore` protocol, so the
/// concrete backing (SecItem on device, in-memory in tests) is injected by the
/// owning `KeepTalkingClient`.
public actor KeepTalkingMCPCredentialStore {
    private let keychain: any KeepTalkingKeychainStore

    public init(keychain: any KeepTalkingKeychainStore) {
        self.keychain = keychain
    }

    /// Persists `credentials` for `actionID`. An empty value clears the entry.
    public func store(
        _ credentials: KeepTalkingMCPCredentials,
        actionID: UUID
    ) async throws {
        let key = KeepTalkingKeychainKey.mcpCredentials(actionID: actionID)
        if credentials.isEmpty {
            try await keychain.delete(key)
            return
        }
        let data = try JSONEncoder().encode(credentials)
        try await keychain.set(key, value: data)
    }

    /// Reads the stored credentials for `actionID`, or `nil` when none exist.
    public func load(actionID: UUID) async throws -> KeepTalkingMCPCredentials? {
        guard
            let data = try await keychain.get(
                .mcpCredentials(actionID: actionID)
            )
        else {
            return nil
        }
        return try JSONDecoder().decode(
            KeepTalkingMCPCredentials.self,
            from: data
        )
    }

    /// Updates only the client secret, preserving any stored headers. A blank
    /// secret clears that field (and the whole entry if no headers remain).
    public func setClientSecret(_ secret: String?, actionID: UUID) async throws {
        var credentials =
            (try? await load(actionID: actionID)) ?? KeepTalkingMCPCredentials()
        let trimmed = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        credentials.clientSecret = (trimmed?.isEmpty == false) ? trimmed : nil
        try await store(credentials, actionID: actionID)
    }

    /// Removes any stored credentials for `actionID`.
    public func delete(actionID: UUID) async throws {
        try await keychain.delete(.mcpCredentials(actionID: actionID))
    }
}
