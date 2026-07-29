import FluentKit
import Foundation

/// One row per outgoing context message that hasn't been actively pushed
/// onto the transport yet. The message itself already lives in the
/// `kt_context_messages` table; this row is purely a delivery hint —
/// "while you have peers/channels, push this envelope again."
///
/// At most one entry per message, enforced by a unique index on
/// `context_message`. Nothing about the attempt is recorded — a failed push
/// leaves the row in place and the next drain retries it, which is the whole
/// contract. Diagnostics go to `onLog?`.
///
/// Removal happens on:
///   • successful `rtcClient.sendEnvelope` after the message landed locally
///   • drain after transport state change (peer connect / broadcast ready)
///
/// Deleting the row does NOT delete the underlying `KeepTalkingContextMessage`
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

    public init() {}

    public init(
        id: UUID = UUID.v7(),
        contextMessage: KeepTalkingContextMessage,
        context: KeepTalkingContext,
        createdAt: Date = Date()
    ) throws {
        self.id = id
        self.$contextMessage.id = try contextMessage.requireID()
        self.$context.id = try context.requireID()
        self.createdAt = createdAt
    }
}
