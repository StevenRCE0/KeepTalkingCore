import FluentKit
import Foundation

public struct KeepTalkingResolvedPushWakePreview: Sendable, Hashable {
    public var title: String
    public var body: String
    public var contextID: UUID
    public var messageID: UUID?

    public init(title: String, body: String, contextID: UUID, messageID: UUID? = nil) {
        self.title = title
        self.body = body
        self.contextID = contextID
        self.messageID = messageID
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
            let preview = try await open(
                envelope,
                as: KeepTalkingPushWakeMessagePreview.self,
                keychain: keychain
            )
        else {
            return nil
        }
        let mappings = try await KeepTalkingMapping.query(on: database)
            .filter(\.$deletedAt == nil)
            .all()
        let senderLabel = KeepTalkingAliasLookup(mappings: mappings)
            .resolve(sender: preview.sender, in: envelope.contextID)
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
            contextID: envelope.contextID,
            messageID: preview.messageID
        )
    }

    /// The message ids a revocation push takes back; nil when this device
    /// holds no secret for the context.
    public static func revokedMessageIDs(
        _ envelope: KeepTalkingPushWakeContextEnvelope,
        keychain: any KeepTalkingKeychainStore
    ) async throws -> [UUID]? {
        try await open(
            envelope,
            as: KeepTalkingPushWakeRevocation.self,
            keychain: keychain
        )?.messageIDs
    }

    private static func open<Payload: Decodable>(
        _ envelope: KeepTalkingPushWakeContextEnvelope,
        as _: Payload.Type,
        keychain: any KeepTalkingKeychainStore
    ) async throws -> Payload? {
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
        return try JSONDecoder().decode(
            Payload.self,
            from: Data(decryptedPayload.utf8)
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
            .resolve(sender: .node(node: payload.senderNodeID), in: payload.contextID)
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
