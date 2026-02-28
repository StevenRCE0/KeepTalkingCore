import Foundation
import LiveKitWebRTC

enum RTCShared {
    private static let defaultPollIntervalNanos: UInt64 = 200_000_000

    static func makeRTCConfiguration(iceServerURLs: [String]) -> LKRTCConfiguration {
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceServers = iceServerURLs.map {
            LKRTCIceServer(urlStrings: [$0], username: nil, credential: nil)
        }
        return config
    }

    static func makePeerConnectionConstraints() -> LKRTCMediaConstraints {
        LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: [
                "DtlsSrtpKeyAgreement": kLKRTCMediaConstraintsValueTrue
            ]
        )
    }

    static func makeDataOnlyOfferAnswerConstraints() -> LKRTCMediaConstraints {
        LKRTCMediaConstraints(
            mandatoryConstraints: [
                kLKRTCMediaConstraintsOfferToReceiveAudio:
                    kLKRTCMediaConstraintsValueFalse,
                kLKRTCMediaConstraintsOfferToReceiveVideo:
                    kLKRTCMediaConstraintsValueFalse,
            ],
            optionalConstraints: nil
        )
    }

    static func createOffer(
        on peer: LKRTCPeerConnection,
        missingSdpError: Error
    ) async throws -> SessionDescriptionPayload {
        let constraints = makeDataOnlyOfferAnswerConstraints()
        return try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: constraints) { offer, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let offer {
                    continuation.resume(returning: toPayload(offer))
                } else {
                    continuation.resume(throwing: missingSdpError)
                }
            }
        }
    }

    static func createAnswer(
        on peer: LKRTCPeerConnection,
        missingSdpError: Error
    ) async throws -> SessionDescriptionPayload {
        let constraints = makeDataOnlyOfferAnswerConstraints()
        return try await withCheckedThrowingContinuation { continuation in
            peer.answer(for: constraints) { answer, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let answer {
                    continuation.resume(returning: toPayload(answer))
                } else {
                    continuation.resume(throwing: missingSdpError)
                }
            }
        }
    }

    static func setLocalDescription(
        _ payload: SessionDescriptionPayload,
        on peer: LKRTCPeerConnection,
        invalidSdpTypeError: (String) -> Error
    ) async throws {
        let description = LKRTCSessionDescription(
            type: try sdpType(from: payload.type, invalidSdpTypeError: invalidSdpTypeError),
            sdp: payload.sdp
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    static func setRemoteDescription(
        _ payload: SessionDescriptionPayload,
        on peer: LKRTCPeerConnection,
        invalidSdpTypeError: (String) -> Error
    ) async throws {
        let description = LKRTCSessionDescription(
            type: try sdpType(from: payload.type, invalidSdpTypeError: invalidSdpTypeError),
            sdp: payload.sdp
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    static func applyOrBufferCandidate(
        _ candidate: LKRTCIceCandidate,
        on peer: LKRTCPeerConnection,
        buffer: inout [LKRTCIceCandidate]
    ) -> Bool {
        guard peer.remoteDescription != nil else {
            buffer.append(candidate)
            return false
        }
        peer.add(candidate) { _ in }
        return true
    }

    static func flushBufferedCandidates(
        on peer: LKRTCPeerConnection,
        buffer: inout [LKRTCIceCandidate]
    ) -> Int {
        let pending = buffer
        buffer.removeAll(keepingCapacity: true)
        for candidate in pending {
            peer.add(candidate) { _ in }
        }
        return pending.count
    }

    static func waitForOpenDataChannel(
        timeoutSeconds: TimeInterval,
        channel: @escaping () -> LKRTCDataChannel?
    ) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            if let channel = channel(), channel.readyState == .open {
                return true
            }
            try? await Task.sleep(nanoseconds: defaultPollIntervalNanos)
        }
        return false
    }

    private static func sdpType(
        from raw: String,
        invalidSdpTypeError: (String) -> Error
    ) throws -> LKRTCSdpType {
        switch raw.lowercased() {
            case "offer":
                return .offer
            case "answer":
                return .answer
            case "pranswer":
                return .prAnswer
            case "rollback":
                return .rollback
            default:
                throw invalidSdpTypeError(raw)
        }
    }

    private static func toPayload(_ description: LKRTCSessionDescription)
        -> SessionDescriptionPayload
    {
        let type: String
        switch description.type {
            case .offer:
                type = "offer"
            case .answer:
                type = "answer"
            case .prAnswer:
                type = "pranswer"
            case .rollback:
                type = "rollback"
            @unknown default:
                type = "offer"
        }
        return SessionDescriptionPayload(type: type, sdp: description.sdp)
    }
}
