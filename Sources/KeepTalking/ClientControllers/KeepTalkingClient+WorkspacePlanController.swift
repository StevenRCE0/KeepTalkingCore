import FluentKit
import Foundation

// MARK: - Workspace plan records
//
// Storage surface for `KeepTalkingWorkspacePlanRecord`. Fulfilled records are
// deleted on completion (host-driven), so any stored record is pending by
// invariant — there is no completed/archived query.

extension KeepTalkingClient {
    /// The newest pending plan record established into the given context.
    public static func workspacePlanRecord(
        for contextID: UUID,
        on database: any Database
    ) async throws -> KeepTalkingWorkspacePlanRecord? {
        try await KeepTalkingWorkspacePlanRecord.query(on: database)
            .filter(\.$context.$id == contextID)
            .sort(\.$updatedAt, .descending)
            .first()
    }

    public func workspacePlanRecord(
        for contextID: UUID
    ) async throws -> KeepTalkingWorkspacePlanRecord? {
        try await Self.workspacePlanRecord(
            for: contextID,
            on: localStore.database
        )
    }

    /// Plan records whose context hasn't been established yet (`context IS
    /// NULL`) — plans exist before their contexts do.
    public static func unestablishedWorkspacePlanRecords(
        on database: any Database
    ) async throws -> [KeepTalkingWorkspacePlanRecord] {
        try await KeepTalkingWorkspacePlanRecord.query(on: database)
            .filter(\.$context.$id == nil)
            .sort(\.$updatedAt, .descending)
            .all()
    }

    public func unestablishedWorkspacePlanRecords()
        async throws -> [KeepTalkingWorkspacePlanRecord]
    {
        try await Self.unestablishedWorkspacePlanRecords(on: localStore.database)
    }

    public static func saveWorkspacePlanRecord(
        _ record: KeepTalkingWorkspacePlanRecord,
        on database: any Database
    ) async throws {
        try await record.save(on: database)
    }

    public func saveWorkspacePlanRecord(
        _ record: KeepTalkingWorkspacePlanRecord
    ) async throws {
        try await Self.saveWorkspacePlanRecord(record, on: localStore.database)
    }

    public static func deleteWorkspacePlanRecord(
        _ record: KeepTalkingWorkspacePlanRecord,
        on database: any Database
    ) async throws {
        try await record.delete(on: database)
    }

    public func deleteWorkspacePlanRecord(
        _ record: KeepTalkingWorkspacePlanRecord
    ) async throws {
        try await Self.deleteWorkspacePlanRecord(record, on: localStore.database)
    }
}
