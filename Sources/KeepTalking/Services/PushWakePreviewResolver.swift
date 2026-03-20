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

public enum KeepTalkingPushWakePreviewResolver {
    public static func resolve(
        _ envelope: KeepTalkingPushWakeContextEnvelope,
        on database: any Database
    ) async throws -> KeepTalkingResolvedPushWakePreview? {
        guard
            let secret = try await KeepTalkingContextGroupSecret.query(on: database)
                .filter(\.$id, .equal, envelope.contextID)
                .first()?
                .secret
        else {
            return nil
        }

        let decryptedPayload = try KeepTalkingContextMessageCrypto.decryptIfNeeded(
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
            .combined(uppercaseID: true)
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
