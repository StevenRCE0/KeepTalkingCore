import Foundation

public enum KeepTalkingEnvelopeChannel: Hashable, Sendable {
    case chat
    case blob
    case actionCall
    case signaling
}
