import FluentKit
import Foundation

/// Fallback integrity sweep for `kt_actions`.
///
/// When a payload shape is retired — a `KeepTalkingAction.Payload` case or a
/// `KeepTalkingPrimitiveActionKind` removed — rows written under the old shape
/// stop decoding and would poison every fetch of the actions table. Rather
/// than pairing each retirement with a bespoke data migration, this sweep runs
/// after every `migrate()`: it reads each row's payload column as raw JSON
/// text through a shadow model, test-decodes it against the current `Payload`,
/// and deletes the rows that no longer decode — grant rows first, action rows
/// second, in one transaction.
enum KeepTalkingUndecodableActionSweep {

    /// Shadow model over `kt_actions` that reads the payload column as raw
    /// JSON text (SQLite stores `.json` fields as text), so undecodable rows
    /// can be identified without tripping the real model's `Payload` decoding.
    private final class RawActionRow: Model, @unchecked Sendable {
        static let schema = KeepTalkingAction.schema

        @ID(key: .id)
        var id: UUID?

        @OptionalField(key: "payload")
        var payload: String?

        init() {}
    }

    static func run(
        on database: any Database,
        log: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let rows = try await RawActionRow.query(on: database).all()
        let decoder = JSONDecoder()
        let undecodableIDs = rows.compactMap { row -> UUID? in
            guard let id = row.id else { return nil }
            guard
                let payload = row.payload,
                let data = payload.data(using: .utf8),
                (try? decoder.decode(KeepTalkingAction.Payload.self, from: data)) != nil
            else { return id }
            return nil
        }
        guard !undecodableIDs.isEmpty else { return }

        try await database.transaction { db in
            try await KeepTalkingNodeRelationActionRelation.query(on: db)
                .filter(\.$action.$id ~~ undecodableIDs)
                .delete()
            try await KeepTalkingAction.query(on: db)
                .filter(\.$id ~~ undecodableIDs)
                .delete()
        }
        log?(
            "[actions-sweep] removed \(undecodableIDs.count) undecodable action row(s): "
                + undecodableIDs.map { $0.uuidString.lowercased() }
                .joined(separator: ", ")
        )
    }
}
