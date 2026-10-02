#if canImport(IrohLib)
import Foundation
import IrohLib

extension KeepTalkingIrohTransportHost {
    /// A point-in-time reading of the endpoints, the SFU session, every
    /// context and every peer link, plus the recent event log. Calls into
    /// iroh per link, so it's for labs, not hot paths.
    @_spi(TransportLab)
    public func instruments() -> KeepTalkingIrohInstruments {
        let snapshot = state.withLockedValue { $0 }
        let sfuConnection = snapshot.sfu.connection
        var sfuStatus: String
        switch snapshot.sfu.status {
            case .idle: sfuStatus = "idle"
            case .connecting(let attempt): sfuStatus = attempt == 0 ? "connecting" : "reconnecting #\(attempt)"
            case .ready: sfuStatus = "ready"
        }
        if snapshot.sfu.suspended { sfuStatus = "suspended" }
        if snapshot.isShutDown { sfuStatus = "shut down" }

        let membership = snapshot.membership
        let peers = snapshot.table.links.map { endpointID, link -> KeepTalkingIrohInstruments.Peer in
            let connection = snapshot.io[endpointID]?.connection
            let paths = connection?.paths() ?? []
            let selected = paths.first(where: \.isSelected)
            let nodeIDs = membership.contexts.values.reduce(into: Set<UUID>()) { result, context in
                for main in context.mains(for: endpointID) {
                    if let node = context.members[main] { result.insert(node) }
                }
            }
            let status: String
            if connection == nil {
                status = "dialing (#\(link.dialAttempts))"
            } else if let reason = connection?.closeReason() {
                status = "closed: \(reason)"
            } else {
                status = link.pathless ? "connected, no path" : "connected"
            }
            return KeepTalkingIrohInstruments.Peer(
                id: Self.hex(endpointID),
                link: link.kind.rawValue,
                nodeIDs: Array(nodeIDs),
                side: link.side.rawValue,
                status: status,
                connectLatencyMs: link.connectLatency.map(Self.milliseconds),
                timeToDirectMs: link.timeToDirect.map(Self.milliseconds),
                isDirect: selected.map { !$0.isRelay } ?? false,
                isBluetooth: selected.map { !$0.isRelay && !$0.isIp } ?? false,
                selectedPath: connection.map(Self.selectedPath),
                rttMs: connection?.rtt(),
                paths: paths.map { path in
                    KeepTalkingIrohInstruments.Path(
                        remoteAddress: path.remoteAddr,
                        kind: Self.pathKind(path),
                        isRelay: path.isRelay,
                        isSelected: path.isSelected,
                        rttMs: path.rttMs
                    )
                },
                framesSent: link.framesSent,
                framesReceived: link.framesReceived,
                bytesSent: link.bytesSent,
                bytesReceived: link.bytesReceived,
                datagramsSent: link.datagramsSent,
                datagramsReceived: link.datagramsReceived,
                lostPackets: connection?.stats().lostPackets
            )
        }
        return KeepTalkingIrohInstruments(
            endpointID: snapshot.myEndpointID.map(Self.hex),
            boundSockets: snapshot.endpoint?.boundSockets() ?? [],
            policy: Self.describe(snapshot.policy),
            sfu: KeepTalkingIrohInstruments.SFU(
                status: sfuStatus,
                sfuID: configuration.sfuEndpointID ?? snapshot.sfu.resolvedID,
                attempts: snapshot.sfu.attempts,
                connectLatencyMs: snapshot.sfu.connectLatency.map(Self.milliseconds),
                connectedSince: snapshot.sfu.connectedSince,
                selectedPath: sfuConnection.map(Self.selectedPath),
                rttMs: sfuConnection?.rtt(),
                queuedBytes: ([Self.sfuSessionQueue] + Lane.allCases.map(Self.sfuQueue))
                    .reduce(0) { $0 + snapshot.outbound.bytes(for: $1) },
                skippedFrames: snapshot.sfu.skippedFrames
            ),
            contexts: snapshot.attachments.compactMap { topic, attachment in
                let context = membership.contexts[topic]
                return KeepTalkingIrohInstruments.Context(
                    id: attachment.topic.contextID,
                    topic: Self.hex(topic),
                    nodeID: attachment.nodeID,
                    joined: context?.joined ?? false,
                    members: (context?.members ?? [:]).map { main, nodeID in
                        KeepTalkingIrohInstruments.Member(
                            nodeID: nodeID,
                            endpointID: Self.hex(main),
                            bluetoothEndpointID: context?.bluetoothOf[main].map { Self.hex($0) },
                            isListedBySFU: context?.unlisted[main] == nil,
                            queuedBytes: Lane.allCases.reduce(0) {
                                $0 + snapshot.outbound.bytes(for: Self.memberQueue(main, $1))
                            }
                        )
                    },
                    meshPublished: attachment.meshPublished,
                    sfuPublished: attachment.sfuPublished,
                    meshReceived: attachment.meshReceived,
                    sfuReceived: attachment.sfuReceived,
                    sfuDatagramsSent: attachment.sfuDatagramsSent,
                    sfuDatagramsReceived: attachment.sfuDatagramsReceived
                )
            },
            peers: peers.sorted { ($0.link, $0.id) < ($1.link, $1.id) },
            bluetooth: configuration.bluetooth == .off ? nil : bluetoothInstruments(snapshot.bluetooth),
            droppedFrames: snapshot.droppedFrames,
            events: snapshot.events
        )
    }

    private func bluetoothInstruments(_ bluetooth: BluetoothState) -> KeepTalkingIrohInstruments.Bluetooth {
        let status = bluetooth.endpoint?.bleStatus()
        let state: String
        if bluetooth.endpoint != nil {
            state = "running"
        } else if bluetooth.starting {
            state = "starting"
        } else if let failure = bluetooth.failure {
            state = "failed: \(failure)"
        } else {
            state = configuration.bluetooth == .whenNetworkFails ? "standby (network fine)" : "stopped"
        }
        return KeepTalkingIrohInstruments.Bluetooth(
            mode: configuration.bluetooth.rawValue,
            state: state,
            endpointID: bluetooth.myID.map(Self.hex),
            starts: bluetooth.starts,
            powered: status?.powered ?? false,
            radioPaused: status?.radioPaused ?? true,
            txBytes: status?.txBytes ?? 0,
            rxBytes: status?.rxBytes ?? 0,
            retransmits: status?.retransmits ?? 0,
            devices: (status?.peers ?? []).map { peer in
                KeepTalkingIrohInstruments.BluetoothDevice(
                    id: peer.deviceId,
                    phase: peer.phase,
                    connectPath: peer.connectPath,
                    endpointID: peer.verifiedEndpoint,
                    prefix: peer.prefix,
                    failures: Int(peer.consecutiveFailures)
                )
            },
            nearby: bluetooth.nearby.keys.map(Self.hex).sorted(),
            strangers: bluetooth.strangers.count
        )
    }

    private static func describe(_ policy: DeliveryPolicy) -> String {
        switch policy {
            case .automatic(let threshold): return "automatic (SFU at ≥\(threshold) members)"
            case .preferMesh: return "prefer mesh"
            case .preferSFU: return "prefer SFU"
        }
    }
}
#endif
