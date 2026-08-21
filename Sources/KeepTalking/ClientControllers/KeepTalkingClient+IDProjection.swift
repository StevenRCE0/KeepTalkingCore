import FluentKit
import Foundation

extension KeepTalkingClient {

    /// Every row's id, projected in SQL — the rows themselves are never loaded.
    ///
    /// The reason this exists rather than `query(on:).all().compactMap(\.id)`:
    /// that form selects every column and decodes a full model per row, which
    /// for a node means its keys, its relations, and its JSON columns. Callers
    /// that only need identity — resolving a name the agent typed, checking
    /// membership, diffing id sets — were paying for all of it.
    ///
    /// Ids are the one thing a caller can always ask for cheaply, so the
    /// projection is generic over any UUID-keyed model rather than per-table.
    public static func allIDs<M: Model>(
        of model: M.Type,
        on database: any Database
    ) async throws -> [UUID] where M.IDValue == UUID {
        try await M.query(on: database).all(\._$id).compactMap { $0 }
    }

    /// See ``allIDs(of:on:)``.
    public func allIDs<M: Model>(
        of model: M.Type
    ) async throws -> [UUID] where M.IDValue == UUID {
        try await Self.allIDs(of: model, on: localStore.database)
    }

    /// Ids of every node this node knows of.
    ///
    /// The candidate set for resolving a node the agent named. Identity only —
    /// nothing here needs a node's keys or relations.
    public func knownNodeIDs() async throws -> [UUID] {
        try await allIDs(of: KeepTalkingNode.self)
    }
}
