import Foundation

/// Per-action ACP agent credentials: the agent subprocess's secret environment
/// (API keys, tokens) plus the auth method the owner last authenticated with.
///
/// These are sensitive and live **only** in the keychain via
/// `KeepTalkingACPCredentialStore` — never in the action's database payload or
/// anything synced to peers. `ACPManager` re-hydrates the environment at spawn
/// time and replays `methodID` so a re-authenticated agent starts silently.
public struct KeepTalkingACPCredentials: Codable, Sendable, Equatable {
    /// Secret environment variables handed to the agent subprocess. The bundle's
    /// own `environment` holds only non-secret values after relocation.
    public var environment: [String: String]
    /// The `AuthMethod.id` that last completed `authenticate` successfully.
    /// Replayed on later spawns so the user is prompted once, not per call.
    public var methodID: String?

    public init(
        environment: [String: String] = [:],
        methodID: String? = nil
    ) {
        self.environment = environment
        self.methodID = methodID
    }

    /// True when there is nothing worth persisting — the store deletes the
    /// keychain entry in that case rather than writing an empty blob.
    public var isEmpty: Bool {
        environment.isEmpty && (methodID?.isEmpty ?? true)
    }
}

/// Keychain-backed store for `KeepTalkingACPCredentials`, keyed by action ID.
///
/// The ACP counterpart of `KeepTalkingMCPCredentialStore`: the single seam
/// through which the SDK persists and reads ACP agent secrets. It talks only to
/// the `KeepTalkingKeychainStore` protocol, so the concrete backing (SecItem on
/// device, in-memory in tests) is injected by the owning `KeepTalkingClient`.
public actor KeepTalkingACPCredentialStore {
    private let keychain: any KeepTalkingKeychainStore

    public init(keychain: any KeepTalkingKeychainStore) {
        self.keychain = keychain
    }

    /// Persists `credentials` for `actionID`. An empty value clears the entry.
    public func store(
        _ credentials: KeepTalkingACPCredentials,
        actionID: UUID
    ) async throws {
        let key = KeepTalkingKeychainKey.acpCredentials(actionID: actionID)
        if credentials.isEmpty {
            try await keychain.delete(key)
            return
        }
        let data = try JSONEncoder().encode(credentials)
        try await keychain.set(key, value: data)
    }

    /// Reads the stored credentials for `actionID`, or `nil` when none exist.
    public func load(actionID: UUID) async throws -> KeepTalkingACPCredentials? {
        guard
            let data = try await keychain.get(
                .acpCredentials(actionID: actionID)
            )
        else {
            return nil
        }
        return try JSONDecoder().decode(
            KeepTalkingACPCredentials.self,
            from: data
        )
    }

    /// Records the auth method that just authenticated, preserving the stored
    /// environment. A blank ID clears that field (and the whole entry if no
    /// environment remains).
    public func setMethodID(_ methodID: String?, actionID: UUID) async throws {
        var credentials =
            (try? await load(actionID: actionID)) ?? KeepTalkingACPCredentials()
        let trimmed = methodID?.trimmingCharacters(in: .whitespacesAndNewlines)
        credentials.methodID = (trimmed?.isEmpty == false) ? trimmed : nil
        try await store(credentials, actionID: actionID)
    }

    /// Removes any stored credentials for `actionID`.
    public func delete(actionID: UUID) async throws {
        try await keychain.delete(.acpCredentials(actionID: actionID))
    }
}
