import Foundation
import LiveKitWebRTC

extension KeepTalkingP2PRTCClient: LKRTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        handleDataChannelDidChangeState(dataChannel)
    }

    func dataChannel(
        _ dataChannel: LKRTCDataChannel,
        didReceiveMessageWith buffer: LKRTCDataBuffer
    ) {
        handleDataChannelDidReceiveMessage(dataChannel, buffer: buffer)
    }
}
