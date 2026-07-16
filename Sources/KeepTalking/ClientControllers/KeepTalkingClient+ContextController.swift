import FluentKit
import Foundation

extension KeepTalkingClient {
    @discardableResult
    public static func createContext(
        contextID: UUID,
        named name: String? = nil,
        on database: any Database
    ) async throws -> KeepTalkingContext {
        let context = try await upsertContext(
            KeepTalkingContext(id: contextID),
            on: database
        )

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            try await setAlias(trimmedName, for: .context(contextID), on: database)
        }

        return context
    }

    @discardableResult
    public func createContext(named name: String? = nil) async throws
        -> KeepTalkingContext
    {
        let context = try await Self.createContext(
            contextID: config.contextID,
            named: name,
            on: localStore.database
        )
        try await ensureGroupChatSecret(for: config.contextID)

        return context
    }

    func upsertContext(_ context: KeepTalkingContext) async throws
        -> KeepTalkingContext
    {
        try await Self.upsertContext(context, on: localStore.database)
    }

    static func upsertContext(
        _ context: KeepTalkingContext,
        on database: any Database
    ) async throws -> KeepTalkingContext {
        guard let contextID = context.id else {
            try await context.save(on: database)
            return context
        }

        if let existing = try await KeepTalkingContext.query(on: database)
            .filter(\.$id, .equal, contextID)
            .first()
        {
            // Forward-only: only advance (and only write) when newer.
            if context.updatedAt > existing.updatedAt {
                existing.updatedAt = context.updatedAt
                try await existing.save(on: database)
            }
            return existing
        }

        try await context.save(on: database)
        return context
    }
}
