import Foundation

public struct KeepTalkingRuntimeStats: Sendable {
    public let sent: Int
    public let received: Int
    public let outboundLabel: String?
    public let outboundState: Int?
    public let inboundLabel: String?
    public let inboundState: Int?
    public let retainedChannels: Int
    public let route: String?
    /// ICE connection state of the publisher peer connection (e.g. "connected", "failed").
    public let publisherIceState: String?
    /// ICE connection state of the subscriber peer connection.
    public let subscriberIceState: String?

    public var outboundIsOpen: Bool {
        outboundState == 1
    }

    public var inboundIsOpen: Bool {
        inboundState == 1
    }

    init(
        sent: Int,
        received: Int,
        outboundLabel: String?,
        outboundState: Int?,
        inboundLabel: String?,
        inboundState: Int?,
        retainedChannels: Int,
        route: String?,
        publisherIceState: String? = nil,
        subscriberIceState: String? = nil
    ) {
        self.sent = sent
        self.received = received
        self.outboundLabel = outboundLabel
        self.outboundState = outboundState
        self.inboundLabel = inboundLabel
        self.inboundState = inboundState
        self.retainedChannels = retainedChannels
        self.route = route
        self.publisherIceState = publisherIceState
        self.subscriberIceState = subscriberIceState
    }
}
