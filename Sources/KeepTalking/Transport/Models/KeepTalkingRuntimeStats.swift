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
        route: String?
    ) {
        self.sent = sent
        self.received = received
        self.outboundLabel = outboundLabel
        self.outboundState = outboundState
        self.inboundLabel = inboundLabel
        self.inboundState = inboundState
        self.retainedChannels = retainedChannels
        self.route = route
    }
}
