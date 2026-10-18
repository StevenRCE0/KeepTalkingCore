import FluentKit
import Foundation

public struct KeepTalkingResolvedPushWakePreview: Sendable, Hashable {
    public var title: String
    public var body: String
    public var contextID: UUID
    public var messageID: UUID?
    /// Who sent it, and how they resolve in the context — for a host that
    /// draws the sender (a communication notification's person).
    public var sender: KeepTalkingContextMessage.Sender?
    public var senderResolution: KeepTalkingAliasResolution?
    /// The node the sender is, or — for an agent — runs on, resolved in the
    /// context. An agent's avatar is drawn from its node's.
    public var senderNodeResolution: KeepTalkingAliasResolution?
    /// How the context itself resolves — its name and appearance.
    public var conversation: KeepTalkingAliasResolution?

    public init(
        title: String,
        body: String,
        contextID: UUID,
        messageID: UUID? = nil,
        sender: KeepTalkingContextMessage.Sender? = nil,
        senderResolution: KeepTalkingAliasResolution? = nil,
        senderNodeResolution: KeepTalkingAliasResolution? = nil,
        conversation: KeepTalkingAliasResolution? = nil
    ) {
        self.title = title
        self.body = body
        self.contextID = contextID
        self.messageID = messageID
        self.sender = sender
        self.senderResolution = senderResolution
        self.senderNodeResolution = senderNodeResolution
        self.conversation = conversation
    }
}

public struct KeepTalkingResolvedPushWakeAction: Sendable, Hashable {
    public var title: String
    public var body: String
    public var contextID: UUID
    /// The node asking to run the action, and how it resolves in the context
    /// — for a host that draws the caller.
    public var callerNodeID: UUID?
    public var callerResolution: KeepTalkingAliasResolution?
    /// How the context itself resolves — its name and appearance.
    public var conversation: KeepTalkingAliasResolution?

    public init(
        title: String,
        body: String,
        contextID: UUID,
        callerNodeID: UUID? = nil,
        callerResolution: KeepTalkingAliasResolution? = nil,
        conversation: KeepTalkingAliasResolution? = nil
    ) {
        self.title = title
        self.body = body
        self.contextID = contextID
        self.callerNodeID = callerNodeID
        self.callerResolution = callerResolution
        self.conversation = conversation
    }
}

public enum KeepTalkingPushWakePreviewResolver {
    /// The node a sender is, or an agent runs on.
    private static func senderNode(of sender: KeepTalkingContextMessage.Sender) -> UUID? {
        switch sender {
            case .node(let node): node
            case .autonomous(_, let node, _): node
        }
    }

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
        let lookup = KeepTalkingAliasLookup(mappings: mappings)
        let senderResolution = lookup.resolve(sender: preview.sender, in: envelope.contextID)
        let senderLabel = senderResolution.primary()
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
            messageID: preview.messageID,
            sender: preview.sender,
            senderResolution: senderResolution,
            senderNodeResolution: senderNode(of: preview.sender).map {
                lookup.resolve(.node($0), in: envelope.contextID)
            },
            conversation: lookup.resolve(.context(envelope.contextID))
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
        let lookup = KeepTalkingAliasLookup(mappings: mappings)
        let callerResolution = lookup.resolve(.node(payload.senderNodeID), in: payload.contextID)
        let callerLabel = callerResolution.primary()
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
            contextID: payload.contextID,
            callerNodeID: payload.senderNodeID,
            callerResolution: callerResolution,
            conversation: lookup.resolve(.context(payload.contextID))
        )
    }
}
