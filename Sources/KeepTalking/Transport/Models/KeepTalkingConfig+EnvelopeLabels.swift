import Foundation

extension KeepTalkingConfig {
    func label(for channel: KeepTalkingEnvelopeChannel) -> String {
        switch channel {
            case .chat:
                return chatChannelLabel
            case .blob:
                return blobChannelLabel
            case .actionCall:
                return actionCallChannelLabel
            case .signaling:
                return signalingChannelLabel
        }
    }
}
