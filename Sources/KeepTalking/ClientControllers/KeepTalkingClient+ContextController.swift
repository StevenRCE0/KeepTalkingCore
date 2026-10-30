import FluentKit
import Foundation

extension KeepTalkingClient {
    @discardableResult
    public static func createContext(
        contextID: UUID,
        named name: String? = nil,
        on database: any Database
    ) async throws -> KeepTalkingContext {
        let context = KeepTalkingContext(id: contextID)
        do {
            try await context.create(on: database)
        } catch {
            guard try await KeepTalkingContext.find(contextID, on: database) != nil else {
                throw error
            }
            throw KeepTalkingClientError.contextAlreadyExists(contextID)
        }

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

    static func requireContext(
        _ contextID: UUID,
        on database: any Database
    ) async throws -> KeepTalkingContext {
        guard let context = try await KeepTalkingContext.find(contextID, on: database) else {
            throw KeepTalkingClientError.missingContext(contextID)
        }
        return context
    }

    func requireContext(_ contextID: UUID) async throws -> KeepTalkingContext {
        try await Self.requireContext(contextID, on: localStore.database)
    }
}
