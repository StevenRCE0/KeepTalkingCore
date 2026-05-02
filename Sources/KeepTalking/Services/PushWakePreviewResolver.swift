import FluentKit
import Foundation

public struct KeepTalkingResolvedPushWakePreview: Sendable, Hashable {
    public var title: String
    public var body: String
    public var contextID: UUID

    public init(title: String, body: String, contextID: UUID) {
        self.title = title
        self.body = body
        self.contextID = contextID
    }
}

public struct KeepTalkingResolvedPushWakeAction: Sendable, Hashable {
    public var title: String
    public var body: String
    public var contextID: UUID

    public init(title: String, body: String, contextID: UUID) {
        self.title = title
        self.body = body
        self.contextID = contextID
    }
}

public enum KeepTalkingPushWakePreviewResolver {
    public static func resolve(
        _ envelope: KeepTalkingPushWakeContextEnvelope,
        on database: any Database,
        keychain: any KeepTalkingKeychainStore
    ) async throws -> KeepTalkingResolvedPushWakePreview? {
        guard
            let secret = try await keychain.get(
                .groupSecret(contextID: envelope.contextID)
            )
        else {
            return nil
        }

        let decryptedPayload =
            try KeepTalkingPreviewCrypto
            .decryptStringIfNeeded(
                envelope.ciphertext,
                secret: secret
            )
        let preview = try JSONDecoder().decode(
            KeepTalkingPushWakeMessagePreview.self,
            from: Data(decryptedPayload.utf8)
        )
        let mappings = try await KeepTalkingMapping.query(on: database)
            .filter(\.$deletedAt == nil)
            .all()
        let senderLabel = KeepTalkingAliasLookup(mappings: mappings)
            .resolve(sender: preview.sender)
            .primary()
        let body =
            if preview.isTruncated, !preview.content.isEmpty {
                preview.content + "…"
            } else {
                preview.content
            }

        return KeepTalkingResolvedPushWakePreview(
            title: senderLabel,
            body: body,
            contextID: envelope.contextID
        )
    }
}

public enum KeepTalkingPushWakeActionResolver {
    public static func resolveNotification(
        _ payload: KeepTalkingPushWakeActionPayload,
        on database: any Database
    ) async throws -> KeepTalkingResolvedPushWakeAction? {
        let mappings = try await KeepTalkingMapping.query(on: database)
            .filter(\.$deletedAt == nil)
            .all()
        let callerLabel = KeepTalkingAliasLookup(mappings: mappings)
            .resolve(sender: .node(node: payload.senderNodeID))
            .primary()
        var actionDescription =
            try await KeepTalkingAction.query(on: database)
            .filter(\.$id, .equal, payload.actionID)
            .first()?
            .wakeDescription
            ?? payload.actionID.uuidString.lowercased()

        actionDescription = "Request to run \(actionDescription)"

        return KeepTalkingResolvedPushWakeAction(
            title: callerLabel,
            body: actionDescription,
            contextID: payload.contextID
        )
    }
}
