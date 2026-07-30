import FluentKit
import Foundation

extension KeepTalkingClient {
    /// Deletes every keychain item belonging to the identity behind `database`.
    ///
    /// The keychain is one flat namespace shared by every identity on the
    /// device — items are keyed by relation, context, and action UUID, none of
    /// which say which identity they came from. `KeepTalkingKeychainStore
    /// .deleteAll()` therefore wipes *all* identities' secrets, which is fine
    /// when only one exists and destructive as soon as a second does.
    ///
    /// Enumerating the owning database instead gives the identity's own key set:
    /// the UUIDs are generated per store, so anything this finds belongs to it
    /// and nothing else.
    ///
    /// Best-effort per item — one failed delete does not abandon the rest, since
    /// a partial sweep still leaves the database gone and the leftovers
    /// unreachable.
    public static func deleteKeychainMaterial(
        on database: any Database,
        keychain: any KeepTalkingKeychainStore
    ) async throws {
        let relationIDs = try await KeepTalkingNodeRelation.query(on: database)
            .all()
            .compactMap(\.id)
        let contextIDs = try await KeepTalkingContext.query(on: database)
            .all()
            .compactMap(\.id)
        let actionIDs = try await KeepTalkingAction.query(on: database)
            .all()
            .compactMap(\.id)

        var keys: [KeepTalkingKeychainKey] = []
        keys.append(contentsOf: relationIDs.map { .nodeIdentityPriv(relationID: $0) })
        keys.append(contentsOf: contextIDs.map { .groupSecret(contextID: $0) })
        keys.append(contentsOf: actionIDs.map { .mcpCredentials(actionID: $0) })

        for key in keys {
            try? await keychain.delete(key)
        }
    }
}
