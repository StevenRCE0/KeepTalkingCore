import Foundation

// MARK: - Result

public struct SFUICEDiagnoseResult: Sendable {
    public enum Outcome: Sendable {
        /// `start()` completed — all required data channels opened.
        case connected
        /// `start()` threw before channels opened.
        case failed(String)
        /// Probe ran longer than `timeoutSeconds` without completing.
        case timeout
    }

    public let outcome: Outcome
    /// ICE connection state of the publisher peer at snapshot time.
    public let publisherIceState: String
    /// ICE connection state of the subscriber peer at snapshot time.
    public let subscriberIceState: String
    /// Wall-clock duration of the probe.
    public let elapsedSeconds: Double

    public var succeeded: Bool {
        if case .connected = outcome { return true }
        return false
    }

    public var summary: String {
        let outcomeStr: String
        switch outcome {
            case .connected:
                outcomeStr = "PASS"
            case .failed(let msg):
                outcomeStr = "FAIL (\(msg))"
            case .timeout:
                outcomeStr = "TIMEOUT"
        }
        return
            "\(outcomeStr) publisher=\(publisherIceState) subscriber=\(subscriberIceState) elapsed=\(String(format: "%.1f", elapsedSeconds))s"
    }
}

// MARK: - Probe

private struct _DiagnoseTimeoutError: Error {}

/// Standalone SFU ICE connectivity probe.
///
/// Creates a temporary `KeepTalkingRTCClient`, connects to the given
/// signaling server, negotiates ICE with the SFU, dumps the ICE snapshot via
/// `onLog`, then tears down. Does **not** require a full `KeepTalkingClient`.
///
/// - Parameters:
///   - signalURL: Ion-SFU WebSocket signaling endpoint.
///   - iceServers: STUN/TURN URLs. Include at least one TURN with `transport=tcp`.
///   - timeoutSeconds: Hard timeout for the entire probe. Default 30 s.
///   - onLog: Receives timestamped debug lines in real time (optional).
/// - Returns: A `SFUICEDiagnoseResult` — always returns, never throws.
public func diagnoseSFUICE(
    signalURL: URL,
    iceServers: [String],
    timeoutSeconds: TimeInterval = 30,
    onLog: (@Sendable (String) -> Void)? = nil
) async -> SFUICEDiagnoseResult {
    let startTime = Date()

    let config = KeepTalkingConfig(
        signalURL: signalURL,
        contextID: UUID(),
        node: UUID(),
        sfuIceServers: iceServers
    )
    let client = KeepTalkingRTCClient(config: config)
    client.onLog = onLog

    let outcome: SFUICEDiagnoseResult.Outcome
    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await client.start() }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)
                )
                throw _DiagnoseTimeoutError()
            }
            // Wait for whichever finishes first, propagate its error (or success).
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                // Drain the cancelled task; swallow its CancellationError.
                while (try? await group.next()) != nil {}
                throw error
            }
            group.cancelAll()
            while (try? await group.next()) != nil {}
        }
        outcome = .connected
    } catch is _DiagnoseTimeoutError {
        outcome = .timeout
    } catch {
        outcome = .failed(error.localizedDescription)
    }

    // Snapshot ICE state (awaited) before tearing down the peer pool.
    await client.snapshotICE()
    let rtStats = client.runtimeStats()
    let elapsed = Date().timeIntervalSince(startTime)

    client.stop()

    return SFUICEDiagnoseResult(
        outcome: outcome,
        publisherIceState: rtStats.publisherIceState ?? "unknown",
        subscriberIceState: rtStats.subscriberIceState ?? "unknown",
        elapsedSeconds: elapsed
    )
}
