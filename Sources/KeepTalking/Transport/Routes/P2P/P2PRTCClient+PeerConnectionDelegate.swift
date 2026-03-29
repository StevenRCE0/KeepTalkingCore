import Foundation
import LiveKitWebRTC

extension KeepTalkingP2PRTCClient: LKRTCPeerConnectionDelegate {
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange stateChanged: LKRTCSignalingState
    ) {
        handlePeerConnectionSignalingStateChange(
            peerConnection,
            stateChanged: stateChanged
        )
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceConnectionState
    ) {
        handlePeerConnectionIceConnectionStateChange(
            peerConnection,
            newState: newState
        )
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceGatheringState
    ) {
        handlePeerConnectionIceGatheringStateChange(
            peerConnection,
            newState: newState
        )
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didGenerate candidate: LKRTCIceCandidate
    ) {
        handlePeerConnectionDidGenerateCandidate(
            peerConnection,
            candidate: candidate
        )
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didRemove candidates: [LKRTCIceCandidate]
    ) {
        handlePeerConnectionDidRemoveCandidates(
            peerConnection,
            candidates: candidates
        )
    }

    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {
        handlePeerConnectionShouldNegotiate(peerConnection)
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didAdd stream: LKRTCMediaStream
    ) {
        handlePeerConnectionDidAddStream(peerConnection, stream: stream)
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didRemove stream: LKRTCMediaStream
    ) {
        handlePeerConnectionDidRemoveStream(peerConnection, stream: stream)
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didOpen dataChannel: LKRTCDataChannel
    ) {
        handlePeerConnectionDidOpenDataChannel(
            peerConnection,
            dataChannel: dataChannel
        )
    }
}
