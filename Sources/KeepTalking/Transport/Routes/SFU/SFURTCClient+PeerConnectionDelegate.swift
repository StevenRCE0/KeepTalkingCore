import Foundation
import LiveKitWebRTC

extension KeepTalkingRTCClient: LKRTCPeerConnectionDelegate {
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

    // Optional delegate methods

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCPeerConnectionState
    ) {
        let tgt = self.target(for: peerConnection) ?? -1
        let name: String
        switch newState {
            case .new: name = "new"
            case .connecting: name = "connecting"
            case .connected: name = "connected"
            case .disconnected: name = "disconnected"
            case .failed: name = "failed"
            case .closed: name = "closed"
            default: name = "unknown(\(newState.rawValue))"
        }
        debug("connection state target=\(tgt) state=\(name)")
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didFailToGatherIceCandidate event: LKRTCIceCandidateErrorEvent
    ) {
        let tgt = self.target(for: peerConnection) ?? -1
        debug(
            "ice candidate gather failed target=\(tgt) url=\(event.url) errorCode=\(event.errorCode) errorText=\(event.errorText) address=\(event.address) port=\(event.port)"
        )
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChangeLocalCandidate local: LKRTCIceCandidate,
        remoteCandidate remote: LKRTCIceCandidate,
        lastReceivedMs: Int32,
        changeReason reason: String
    ) {
        let tgt = self.target(for: peerConnection) ?? -1
        debug(
            "selected pair changed target=\(tgt) local=\(local.sdp) remote=\(remote.sdp) reason=\(reason)"
        )
    }
}
