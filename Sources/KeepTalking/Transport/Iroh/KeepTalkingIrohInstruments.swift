import Foundation

/// A reading of a `KeepTalkingIrohTransportHost`: endpoint, SFU session,
/// attached contexts, peer links and recent events. Values are plain data so
/// a lab can poll and diff them.
@_spi(TransportLab)
public struct KeepTalkingIrohInstruments: Sendable {
    public struct SFU: Sendable {
        public var status: String
        /// Configured, or looked up at `<relay>/kt/sfu`; nil until known.
        public var sfuID: String?
        /// Connect attempts so far, including the current one.
        public var attempts: Int
        public var connectLatencyMs: Double?
        public var connectedSince: Date?
        public var selectedPath: String?
        public var rttMs: UInt64?
        /// Bytes waiting in the SFU queue.
        public var queuedBytes: Int
        /// Frames from the SFU that didn't parse and were skipped.
        public var skippedFrames: Int
    }

    public struct Member: Sendable, Hashable {
        public var nodeID: UUID
        public var endpointID: String
        /// The member's Bluetooth endpoint, if its presence announced one.
        public var bluetoothEndpointID: String?
        /// False while the SFU doesn't list the member; it stays while a
        /// link reaches it or Bluetooth may.
        public var isListedBySFU: Bool
        /// Bytes waiting in the member's queue.
        public var queuedBytes: Int
    }

    public struct Context: Sendable, Identifiable {
        public var id: UUID
        /// The routing key (hex) derived from the context secret.
        public var topic: String
        public var nodeID: UUID
        /// The SFU's snapshot for this topic has arrived.
        public var joined: Bool
        /// Members whose sealed presence opened with the context secret.
        public var members: [Member]
        /// Publishes sent over the mesh / through the SFU.
        public var meshPublished: Int
        public var sfuPublished: Int
        /// Frames received from peer links / delivered by the SFU.
        public var meshReceived: Int
        public var sfuReceived: Int
        public var sfuDatagramsSent: Int
        public var sfuDatagramsReceived: Int

        public var shortTopic: String { String(topic.prefix(10)) }
    }

    public struct Path: Sendable, Hashable {
        public var remoteAddress: String
        /// `relay`, `ip` or `bluetooth`.
        public var kind: String
        public var isRelay: Bool
        public var isSelected: Bool
        public var rttMs: UInt64
    }

    public struct Peer: Sendable, Identifiable {
        /// Remote endpoint id (hex).
        public var id: String
        /// `network` (relay/IP endpoint) or `bluetooth` (Bluetooth-only endpoint).
        public var link: String
        public var nodeIDs: [UUID]
        /// `dialed` (our turn: the lower id on the network, the higher over
        /// Bluetooth) or `accepted`.
        public var side: String
        public var status: String
        public var connectLatencyMs: Double?
        /// Time from connect until a direct path was first selected.
        public var timeToDirectMs: Double?
        /// The selected path skips the relay (IP or Bluetooth).
        public var isDirect: Bool
        /// The selected path is Bluetooth.
        public var isBluetooth: Bool
        public var selectedPath: String?
        public var rttMs: UInt64?
        public var paths: [Path]
        public var framesSent: Int
        public var framesReceived: Int
        public var bytesSent: Int
        public var bytesReceived: Int
        public var datagramsSent: Int
        public var datagramsReceived: Int
        public var lostPackets: Int64?

        public var shortID: String { String(id.prefix(10)) }
    }

    /// The Bluetooth endpoint, when the host was configured with one.
    public struct Bluetooth: Sendable {
        /// `always` or `whenNetworkFails`.
        public var mode: String
        /// `running`, `standby (network fine)`, `starting`, `stopped`, `failed: …`.
        public var state: String
        /// Our Bluetooth endpoint id (hex), fixed for the process.
        public var endpointID: String?
        /// How many times this host has claimed the endpoint.
        public var starts: Int
        /// Adapter on and permission granted (false while stopped).
        public var powered: Bool
        /// The radio is paused: no scanning or advertising.
        public var radioPaused: Bool
        public var txBytes: UInt64
        public var rxBytes: UInt64
        public var retransmits: UInt64
        public var devices: [BluetoothDevice]
        /// Bluetooth ids read from nearby devices (hex), for offline
        /// discovery.
        public var nearby: [String]
        /// Nearby ids whose hello shared no context with us.
        public var strangers: Int
    }

    public struct BluetoothDevice: Sendable, Identifiable {
        public var id: String
        /// `Discovered`, `Connecting`, `Connected`, …
        public var phase: String
        /// `Gatt` or `L2cap` once a data pipe exists.
        public var connectPath: String?
        /// The peer's endpoint id (hex) once its handshake verified it.
        public var endpointID: String?
        /// The key prefix (hex) it advertises.
        public var prefix: String?
        public var failures: Int
    }

    public struct Event: Sendable, Identifiable {
        public let id: Int
        public let at: Date
        public let text: String
    }

    public var endpointID: String?
    public var boundSockets: [String]
    /// Human-readable `DeliveryPolicy`.
    public var policy: String
    public var sfu: SFU
    public var contexts: [Context]
    public var peers: [Peer]
    public var bluetooth: Bluetooth?
    /// Peer frames dropped because no attached context has their topic.
    public var droppedFrames: Int
    public var events: [Event]
}
