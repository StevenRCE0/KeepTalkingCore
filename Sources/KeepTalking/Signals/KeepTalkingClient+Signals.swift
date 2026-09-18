import Foundation

extension KeepTalkingClient {
    /// Flattens ``KeepTalkingClientSignals`` onto the client, so
    /// `client.envelopes`, `client.lifecycle`, … resolve to the box's members
    /// through the key path — typed, read-only, and with nothing to keep in
    /// sync when a signal is added. The box stays the documented surface.
    public subscript<Member>(
        dynamicMember keyPath: KeyPath<KeepTalkingClientSignals, Member>
    ) -> Member {
        signals[keyPath: keyPath]
    }
}
