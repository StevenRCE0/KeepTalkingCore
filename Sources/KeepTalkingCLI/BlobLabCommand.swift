import Foundation
import KeepTalkingSDK

/// SFU-assisted blob lab over libjuice-discovered direct HTTP/2.
///
/// The SFU carries SDP and TCP-port signaling on `.p2pSignal`; libjuice
/// proves reachability, then blob bytes move as one direct HTTP/2
/// message (TLS over TCP).
enum BlobLabCommand {
    private struct Signal: Codable, Sendable {
        let kind: String
        let sdp: String?
        let port: UInt16?
    }

    private struct Args {
        var role = "listen"
        var host = "127.0.0.1"
        var port: UInt16 = 9701
        var context = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        var node = UUID()
        var peerHex: String?
        var bytes = 4096
        var timeout: TimeInterval = 30
    }

    static func shouldHandle(_ args: [String]) -> Bool {
        args.first == "bloblab"
    }

    static func run(_ args: [String]) async {
        do {
            let parsed = try parse(args)
            try await run(parsed)
            Foundation.exit(0)
        } catch {
            stderr("error: \(error.localizedDescription)")
            usage()
            Foundation.exit(1)
        }
    }

    private static func run(_ args: Args) async throws {
        let signingKey = KeepTalkingSFUSigningKey.ephemeral()
        let config = KeepTalkingConfig(
            contextID: args.context,
            node: args.node
        )
        let sfu = KeepTalkingSFUJuiceSession(
            config: config,
            sfuHost: args.host,
            sfuPort: args.port,
            signingKey: signingKey
        )
        let peerBox = LockedBox<Data?>(args.peerHex.flatMap(hexData))
        let localSDPBox = LockedBox<String?>(nil)
        let remoteHostBox = LockedBox<String?>(nil)
        let pendingH2PortBox = LockedBox<UInt16?>(nil)
        let h2Box = LockedBox<KeepTalkingBlobHTTP2Channel?>(nil)
        let done = OneShot()
        let h2Connected = OneShot()

        let p2p = try KeepTalkingJuiceP2PSession()
        let startH2: @Sendable (KeepTalkingBlobHTTP2Channel.Role) -> Void = { role in
            if h2Box.get() != nil { return }
            let h2 = KeepTalkingBlobHTTP2Channel(role: role)
            h2Box.set(h2)
            h2.onLog = { stderr("[h2] \($0)") }
            h2.onState = { state in
                stderr("[h2] state=\(state)")
                if case .ready(let port?) = state, let peer = peerBox.get() {
                    sendH2Port(port, to: peer, via: sfu)
                }
                if case .connected = state {
                    h2Connected.signal()
                }
                if case .failed(let reason) = state {
                    stderr("[h2] failed=\(reason)")
                    done.signal()
                }
            }
            h2.onMessage = { data in
                stderr("[blob] recv bytes=\(data.count)")
                done.signal()
            }
            h2.start()
        }

        p2p.onLog = { stderr($0) }
        p2p.onLocalSDPReady = { sdp in
            localSDPBox.set(sdp)
            if let peer = peerBox.get() {
                sendSDP(sdp, to: peer, via: sfu)
            }
        }
        p2p.onState = { state in
            stderr("[p2p] state=\(state)")
            if case .connected = state {
                guard let pair = p2p.selectedAddresses(),
                    let (remoteHost, _) = Self.parseAddress(pair.remote)
                else {
                    stderr("[p2p] connected but selected remote address unavailable")
                    done.signal()
                    return
                }
                remoteHostBox.set(remoteHost)
                if args.role == "listen" {
                    startH2(.listener)
                } else if let port = pendingH2PortBox.get() {
                    startH2(.initiator(host: remoteHost, port: port))
                } else {
                    stderr("[h2] waiting for peer listener port")
                }
            }
            if case .failed(let reason) = state {
                stderr("[p2p] failed=\(reason)")
                done.signal()
            }
        }

        sfu.onLog = { stderr("[sfu] \($0)") }
        sfu.onPresence = { event in
            switch event {
                case .snapshot(_, let peers):
                    rememberPeer(peers, selfKey: sfu.publicKey, peerBox: peerBox, localSDPBox: localSDPBox, sfu: sfu)
                case .joined(_, let peer):
                    rememberPeer([peer], selfKey: sfu.publicKey, peerBox: peerBox, localSDPBox: localSDPBox, sfu: sfu)
                case .left:
                    break
            }
        }
        sfu.onInbound = { payload in
            guard case .opaqueBytes(let data, let channel, let sender) = payload,
                channel == .p2pSignal,
                sender != sfu.publicKey,
                let signal = try? JSONDecoder().decode(Signal.self, from: data)
            else {
                return
            }
            if peerBox.get() == nil {
                peerBox.set(sender)
            }
            switch signal.kind {
                case "juice-sdp":
                    guard let sdp = signal.sdp else { return }
                    stderr("[signal] recv sdp bytes=\(sdp.utf8.count)")
                    p2p.applyRemoteSDP(sdp)
                    if let localSDP = localSDPBox.get() {
                        sendSDP(localSDP, to: sender, via: sfu)
                    }
                case "h2-port":
                    guard let port = signal.port else { return }
                    pendingH2PortBox.set(port)
                    stderr("[signal] recv h2 port=\(port)")
                    if args.role == "connect", let host = remoteHostBox.get() {
                        startH2(.initiator(host: host, port: port))
                    }
                default:
                    break
            }
        }

        try await sfu.start()
        stderr("[lab] node=\(args.node.uuidString.lowercased()) pubkey=\(hex(sfu.publicKey))")
        p2p.start()
        sfu.requestPeerRoster()

        let timer = Task {
            try? await Task.sleep(for: .seconds(args.timeout))
            stderr("[lab] timeout after \(args.timeout)s")
            h2Connected.signal()
            done.signal()
        }

        if args.role == "connect" {
            await h2Connected.wait()
            guard let h2 = h2Box.get() else {
                throw LabError.badArgs("HTTP/2 did not connect")
            }
            try h2.send(deterministic(args.bytes))
            stderr("[blob] sent bytes=\(args.bytes)")
            done.signal()
        } else {
            await done.wait()
        }

        timer.cancel()
        h2Box.get()?.close()
        p2p.close()
        sfu.stop()
    }

    private static func rememberPeer(
        _ peers: [Data],
        selfKey: Data,
        peerBox: LockedBox<Data?>,
        localSDPBox: LockedBox<String?>,
        sfu: KeepTalkingSFUJuiceSession
    ) {
        guard peerBox.get() == nil,
            let peer = peers.first(where: { $0 != selfKey })
        else {
            return
        }
        peerBox.set(peer)
        stderr("[presence] peer=\(hex(peer))")
        if let localSDP = localSDPBox.get() {
            sendSDP(localSDP, to: peer, via: sfu)
        }
    }

    private static func sendSDP(_ sdp: String, to peer: Data, via sfu: KeepTalkingSFUJuiceSession) {
        guard let payload = try? JSONEncoder().encode(Signal(kind: "juice-sdp", sdp: sdp, port: nil)) else {
            return
        }
        sfu.routeRawBytes(payload, to: peer, channel: .p2pSignal)
        stderr("[signal] sent sdp bytes=\(sdp.utf8.count)")
    }

    private static func sendH2Port(_ port: UInt16, to peer: Data, via sfu: KeepTalkingSFUJuiceSession) {
        guard let payload = try? JSONEncoder().encode(Signal(kind: "h2-port", sdp: nil, port: port)) else {
            return
        }
        sfu.routeRawBytes(payload, to: peer, channel: .p2pSignal)
        stderr("[signal] sent h2 port=\(port)")
    }

    private static func parseAddress(_ value: String) -> (host: String, port: UInt16)? {
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<end])
            let after = value.index(after: end)
            guard after < value.endIndex, value[after] == ":" else { return nil }
            guard let port = UInt16(value[value.index(after: after)...]) else { return nil }
            return (host, port)
        }
        guard let colon = value.lastIndex(of: ":"),
            let port = UInt16(value[value.index(after: colon)...])
        else { return nil }
        return (String(value[..<colon]), port)
    }

    private static func parse(_ args: [String]) throws -> Args {
        var out = Args()
        var tokens = args
        if let first = tokens.first, first == "listen" || first == "connect" {
            out.role = first
            tokens.removeFirst()
        }
        var index = 0
        while index < tokens.count {
            let arg = tokens[index]
            func next() throws -> String {
                guard index + 1 < tokens.count else { throw LabError.badArgs("\(arg) requires a value") }
                index += 1
                return tokens[index]
            }
            switch arg {
                case "--sfu":
                    let parts = try next().split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2, let port = UInt16(parts[1]) else {
                        throw LabError.badArgs("--sfu expects host:port")
                    }
                    out.host = parts[0]
                    out.port = port
                case "--context":
                    guard let value = UUID(uuidString: try next()) else { throw LabError.badArgs("invalid context") }
                    out.context = value
                case "--node":
                    guard let value = UUID(uuidString: try next()) else { throw LabError.badArgs("invalid node") }
                    out.node = value
                case "--peer":
                    out.peerHex = try next()
                case "--bytes":
                    guard let value = Int(try next()), value >= 0 else { throw LabError.badArgs("invalid bytes") }
                    out.bytes = value
                case "--timeout":
                    guard let value = TimeInterval(try next()), value > 0 else {
                        throw LabError.badArgs("invalid timeout")
                    }
                    out.timeout = value
                default:
                    throw LabError.badArgs("unknown arg \(arg)")
            }
            index += 1
        }
        return out
    }

    private static func deterministic(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes {
            let bytes = $0.bindMemory(to: UInt8.self)
            for index in 0..<bytes.count {
                bytes[index] = UInt8(index & 0xff)
            }
        }
        return data
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexData(_ raw: String) -> Data? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var out = Data()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    private static func usage() {
        stderr(
            """
            Usage:
              KeepTalking bloblab listen  --sfu host:port --context <uuid> [--node <uuid>] [--timeout 30]
              KeepTalking bloblab connect --sfu host:port --context <uuid> [--node <uuid>] [--peer <hex>] [--bytes 4096]
            """)
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private enum LabError: LocalizedError {
        case badArgs(String)

        var errorDescription: String? {
            switch self {
                case .badArgs(let message): return message
            }
        }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var didSignal = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didSignal {
                lock.unlock()
                continuation.resume()
                return
            }
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func signal() {
        lock.lock()
        guard !didSignal else {
            lock.unlock()
            return
        }
        didSignal = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}
