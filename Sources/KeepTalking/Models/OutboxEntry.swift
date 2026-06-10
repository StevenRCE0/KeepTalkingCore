import FluentKit
import Foundation

/// One row per outgoing context message that hasn't been actively pushed
/// onto the transport yet. The message itself already lives in the
/// `kt_context_messages` table; this row is purely a delivery hint —
/// "while you have peers/channels, push this envelope again."
///
/// Modelled as a child of both `KeepTalkingContext` and
/// `KeepTalkingContextMessage` so we can navigate the relation in either
/// direction without secondary lookups, and so we don't need a migration
/// on either parent table — the FKs live entirely on this row.
///
/// Removal happens on:
///   • successful `rtcClient.sendEnvelope` after the message landed locally
///   • drain after transport state change (peer connect / broadcast ready)
///   • explicit user cancellation (from the UI's outbox indicator)
///
/// Cancellation does NOT delete the underlying `KeepTalkingContextMessage`
/// — the message stays in the context and is eventually delivered through
/// regular context sync when peers reconnect and pull deltas.
public final class KeepTalkingOutboxEntry: Model, @unchecked Sendable {
    public static let schema = "kt_outbox_entries"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "context")
    public var context: KeepTalkingContext

    @Parent(key: "context_message")
    public var contextMessage: KeepTalkingContextMessage

    @Field(key: "created_at")
    public var createdAt: Date

    @Field(key: "attempts")
    public var attempts: Int

    @OptionalField(key: "last_error")
    public var lastError: String?

    public init() {}

    public init(
        id: UUID = UUID.v7(),
        contextMessage: KeepTalkingContextMessage,
        context: KeepTalkingContext,
        createdAt: Date = Date(),
        attempts: Int = 0,
        lastError: String? = nil
    ) throws {
        self.id = id
        self.$contextMessage.id = try contextMessage.requireID()
        self.$context.id = try context.requireID()
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastError = lastError
    }
}
