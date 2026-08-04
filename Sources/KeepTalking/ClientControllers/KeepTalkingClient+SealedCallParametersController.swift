import Foundation
import MCP

/// Canonical presentation order for tool-call parameters.
///
/// Every surface that shows a call's arguments — the approval alert, the
/// continuation card, the chat tool-hint inspector — sorts through here, so the
/// same call reads the same way wherever the user meets it.
public enum KeepTalkingCallParameters {
    /// Operationally interesting keys first, then everything else
    /// alphabetically. Keeps a script result readable instead of burying
    /// `stdout` / `exit_code` under arbitrary metadata.
    private static let priorityKeys = [
        "command", "exit_code", "stdout", "stderr", "summary", "result",
    ]

    public static func ordered(
        _ parameters: [String: String]
    ) -> [(key: String, value: String)] {
        let priorityIndex = Dictionary(
            uniqueKeysWithValues: priorityKeys.enumerated().map { ($1, $0) }
        )
        return parameters.sorted { lhs, rhs in
            switch (priorityIndex[lhs.key], priorityIndex[rhs.key]) {
                case (let l?, let r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.key < rhs.key
            }
        }
        .map { (key: $0.key, value: $0.value) }
    }

    /// Flattens MCP argument values to the display strings KT stores for tool
    /// hints. Mirrors how the agent controller renders `run_action` arguments so
    /// an approval prompt and its later tool-hint row agree.
    public static func displayStrings(
        from arguments: [String: Value]
    ) -> [String: String] {
        arguments.reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value.stringValue ?? entry.value.description
        }
    }
}

extension KeepTalkingClient {
    static let sealedParametersPurpose = "call-parameters"

    /// Seals tool-call parameters so only the two ends of the call can read them.
    ///
    /// Arguments are the most revealing thing an agent turn produces — a shell
    /// command, a file path, a search query — and the `.intermediate` row that
    /// carries them is a context message, so it replicates to every member of
    /// the context rather than just the peer being asked to do the work. Sealing
    /// them to the executor keeps the row itself (hint, action, target node)
    /// legible to everyone while the arguments stay between caller and callee.
    ///
    /// `peerNodeID == nil` is a built-in or local tool: it seals to this node
    /// via the local identity relation, where caller and callee are the same
    /// party — and where no other peer is entitled to the contents either.
    func sealCallParameters(
        _ parameters: [String: String],
        for peerNodeID: UUID?
    ) async -> Data? {
        guard !parameters.isEmpty else { return nil }
        do {
            let encoded = try JSONEncoder().encode(parameters)
            let envelope = try await encryptAsymmetricPayload(
                encoded,
                recipientNodeID: peerNodeID ?? config.node,
                purpose: Self.sealedParametersPurpose
            )
            return try JSONEncoder().encode(envelope)
        } catch {
            // A hint row is never worth failing a turn over: drop the arguments
            // and let the row render without them.
            onLog?(
                "[sealed-params] seal failed peer=\(peerNodeID?.uuidString.lowercased() ?? "self"): \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Opens parameters sealed by `sealCallParameters`, from either end of the
    /// call. Returns nil for anyone else — which is the point: a third peer
    /// holds the row but not the key material, so its inspector simply has
    /// nothing to show.
    public func openSealedCallParameters(
        _ sealed: Data
    ) async -> [String: String]? {
        guard
            let envelope = try? JSONDecoder().decode(
                KeepTalkingAsymmetricCipherEnvelope.self,
                from: sealed
            )
        else {
            return nil
        }

        guard
            let payload = await openAsymmetricPayloadFromEitherEnd(
                envelope,
                purpose: Self.sealedParametersPurpose
            )
        else {
            return nil
        }
        return try? JSONDecoder().decode([String: String].self, from: payload)
    }

    /// The arguments a suspended continuation is asking permission to run.
    ///
    /// The request is already sealed inside the continuation message, so this
    /// resolves for exactly the two nodes that matter — the agent that asked and
    /// the user being asked — and returns nil on every other peer's copy of the
    /// same message.
    public func continuationCallParameters(
        for message: KeepTalkingContextMessage
    ) async -> [String: String]? {
        guard
            case .agentTurnContinuation(
                _, _, let targetNodeID, _, let encryptedPayload, _
            ) = message.type,
            let originNodeID = message.sender.nodeID
        else {
            return nil
        }

        let envelope = KeepTalkingAsymmetricCipherEnvelope(
            senderNodeID: originNodeID,
            recipientNodeID: targetNodeID,
            ciphertext: encryptedPayload
        )
        guard
            let payload = await openAsymmetricPayloadFromEitherEnd(
                envelope,
                purpose: "action-call-request"
            ),
            let request = try? JSONDecoder().decode(
                KeepTalkingActionCallRequest.self,
                from: payload
            )
        else {
            return nil
        }

        let parameters = KeepTalkingCallParameters.displayStrings(
            from: request.call.arguments
        )
        return parameters.isEmpty ? nil : parameters
    }

    /// Tries the recipient path, then the sender path. One of the two succeeds
    /// on each end of a call; neither does anywhere else.
    private func openAsymmetricPayloadFromEitherEnd(
        _ envelope: KeepTalkingAsymmetricCipherEnvelope,
        purpose: String
    ) async -> Data? {
        if envelope.recipientNodeID == config.node,
            let payload = try? await decryptAsymmetricPayload(
                envelope,
                expectedSenderNodeID: envelope.senderNodeID,
                purpose: purpose
            )
        {
            return payload
        }
        if envelope.senderNodeID == config.node,
            let payload = try? await decryptAsymmetricPayloadAsSender(
                envelope,
                purpose: purpose
            )
        {
            return payload
        }
        return nil
    }
}
