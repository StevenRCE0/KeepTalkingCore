import Foundation
import KeepTalkingSFUClient
import NIOCore
import NIOFoundationCompat
import NIOHPACK
import NIOHTTP2
import NIOPosix
import NIOSSL

/// Direct-peer data carrier: a single long-lived bidirectional HTTP/2
/// stream between two peers, TLS over TCP. Replaces the previous QUIC
/// carrier — wire shape on top of HTTP/2 is unchanged (4-byte BE length
/// prefix + payload), so the existing `BlobLab` framing keeps working.
///
/// Role selection mirrors the QUIC version: the lexicographically-lower
/// node-ID listens, the higher dials. libjuice's ICE handshake still
/// provides reachability; the listener publishes its TCP port over the
/// existing p2p signal channel.
///
/// Why HTTP/2 here instead of raw TCP? Because the SDK uses NIOHTTP2 for
/// its SFU client too, so the same TLS+H2 setup, certificate-validation
/// posture, and `NIOSSLPKCS12Bundle` lab cert flow can be reused
/// verbatim. A pure-TCP variant is possible later if the H2 overhead
/// becomes measurable; for now uniformity wins.
public final class KeepTalkingBlobHTTP2Channel: @unchecked Sendable {
    public enum Role: Sendable, Equatable {
        case listener
        case initiator(host: String, port: UInt16)
    }

    public enum State: Sendable, Equatable, CustomStringConvertible {
        case idle
        case ready(localPort: UInt16?)
        case connected
        case failed(String)
        case closed

        public var description: String {
            switch self {
                case .idle: return "idle"
                case .ready(let port): return port.map { "ready(port=\($0))" } ?? "ready"
                case .connected: return "connected"
                case .failed(let reason): return "failed(\(reason))"
                case .closed: return "closed"
            }
        }
    }

    public var onState: (@Sendable (State) -> Void)?
    public var onMessage: (@Sendable (Data) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    private let role: Role
    private let stateLock = NSLock()
    private var state: State = .idle {
        didSet { onState?(state) }
    }
    private var group: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var connectionChannel: Channel?
    private var dataChannel: Channel?
    private var receiveBuffer = Data()

    public init(role: Role) {
        self.role = role
    }

    public func start() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        switch role {
            case .listener:
                startListener(group: group)
            case .initiator(let host, let port):
                startInitiator(group: group, host: host, port: port)
        }
    }

    public func send(_ data: Data) throws {
        let channel: Channel? = stateLock.sync { dataChannel }
        guard let channel else { throw Error.notConnected }
        var buffer = channel.allocator.buffer(capacity: 4 + data.count)
        buffer.writeInteger(UInt32(data.count), endianness: .big)
        buffer.writeBytes(data)
        let frame = HTTP2Frame.FramePayload.data(
            .init(data: .byteBuffer(buffer), endStream: false)
        )
        channel.eventLoop.execute {
            channel.writeAndFlush(frame, promise: nil)
        }
    }

    public func close() {
        let data = stateLock.sync { dataChannel }
        let parent = stateLock.sync { connectionChannel }
        let server = stateLock.sync { serverChannel }
        let g = stateLock.sync { group }
        stateLock.sync {
            dataChannel = nil
            connectionChannel = nil
            serverChannel = nil
            group = nil
            receiveBuffer.removeAll()
        }
        data?.close(promise: nil)
        parent?.close(promise: nil)
        server?.close(promise: nil)
        if let g {
            DispatchQueue.global().async { try? g.syncShutdownGracefully() }
        }
        state = .closed
        emit("closed")
    }

    // MARK: - Listener side

    private func startListener(group: MultiThreadedEventLoopGroup) {
        let sslContext: NIOSSLContext
        do {
            sslContext = try Self.makeServerTLSContext()
        } catch {
            state = .failed("tls: \(error)")
            return
        }
        let weakSelf = WeakBox(self)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 4)
            // TCP keepalive on the accepted child socket so we notice
            // silent peer death (Wi-Fi switch, peer device crash) instead
            // of trusting OS keepalives' multi-hour defaults.
            .childChannelOption(
                ChannelOptions.socketOption(.so_keepalive),
                value: 1
            )
            .childChannelInitializer { channel in
                // Watch the connection-level channel: if it closes, the
                // carrier moves to .failed even if no stream-level event
                // fires (RST under load, abrupt TLS shutdown, etc.).
                channel.closeFuture.whenComplete { _ in
                    weakSelf.value?.handleConnectionLost(reason: "child channel closed")
                }
                let sslHandler = NIOSSLServerHandler(context: sslContext)
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(sslHandler)
                    try channel.pipeline.syncOperations.addHandler(HTTP2KeepAliveHandler())
                }.flatMap {
                    channel.configureHTTP2Pipeline(
                        mode: .server,
                        inboundStreamInitializer: { streamChannel in
                            let handler = BlobStreamHandler(
                                role: .server,
                                onMessage: { [weakSelf] data in
                                    weakSelf.value?.onMessage?(data)
                                },
                                onReady: { [weakSelf] streamChannel in
                                    weakSelf.value?.markDataChannel(streamChannel)
                                },
                                onClose: { [weakSelf] reason in
                                    weakSelf.value?.handleStreamClosed(reason: reason)
                                }
                            )
                            return streamChannel.pipeline.addHandler(handler)
                        }
                    ).map { _ in () }
                }
            }

        bootstrap.bind(host: "::", port: 0).whenComplete { result in
            switch result {
                case .success(let channel):
                    self.stateLock.sync { self.serverChannel = channel }
                    let port = channel.localAddress?.port.map { UInt16($0) }
                    self.state = .ready(localPort: port)
                    self.emit("listener ready port=\(port.map(String.init) ?? "n/a")")
                case .failure(let err):
                    self.state = .failed("bind: \(err.localizedDescription)")
            }
        }
    }

    // MARK: - Initiator side

    private func startInitiator(group: MultiThreadedEventLoopGroup, host: String, port: UInt16) {
        let sslContext: NIOSSLContext
        do {
            sslContext = try Self.makeClientTLSContext()
        } catch {
            state = .failed("tls: \(error)")
            return
        }
        let weakSelf = WeakBox(self)
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                let ssl: NIOSSLClientHandler
                do {
                    ssl = try NIOSSLClientHandler(context: sslContext, serverHostname: nil)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ssl)
                    try channel.pipeline.syncOperations.addHandler(HTTP2KeepAliveHandler())
                }.flatMap {
                    channel.configureHTTP2Pipeline(mode: .client) { _ in
                        channel.eventLoop.makeSucceededVoidFuture()
                    }.map { _ in () }
                }
            }
        emit("dialing \(host):\(port)")
        bootstrap.connect(host: host, port: Int(port)).whenComplete { result in
            switch result {
                case .success(let channel):
                    self.stateLock.sync { self.connectionChannel = channel }
                    channel.closeFuture.whenComplete { _ in
                        weakSelf.value?.handleConnectionLost(reason: "client channel closed")
                    }
                    channel.eventLoop.execute {
                        channel.pipeline.handler(type: HTTP2StreamMultiplexer.self).whenComplete { muxResult in
                            switch muxResult {
                                case .success(let mux):
                                    weakSelf.value?.openInitiatorStream(via: mux)
                                case .failure(let err):
                                    self.state = .failed("mux: \(err.localizedDescription)")
                            }
                        }
                    }
                case .failure(let err):
                    self.state = .failed("connect \(host):\(port): \(String(reflecting: err))")
            }
        }
    }

    private func openInitiatorStream(via mux: HTTP2StreamMultiplexer) {
        let weakSelf = WeakBox(self)
        mux.createStreamChannel(promise: nil) { streamChannel in
            let handler = BlobStreamHandler(
                role: .client,
                onMessage: { [weakSelf] data in
                    weakSelf.value?.onMessage?(data)
                },
                onReady: { [weakSelf] streamChannel in
                    weakSelf.value?.markDataChannel(streamChannel)
                },
                onClose: { [weakSelf] reason in
                    weakSelf.value?.handleStreamClosed(reason: reason)
                }
            )
            return streamChannel.pipeline.addHandler(handler).map {
                // Emit request headers to open the stream.
                var headers = HPACKHeaders()
                headers.add(name: ":method", value: "POST")
                headers.add(name: ":scheme", value: "https")
                headers.add(name: ":path", value: "/blob")
                headers.add(name: ":authority", value: "kt-blob")
                headers.add(name: "content-type", value: "application/octet-stream")
                let frame = HTTP2Frame.FramePayload.headers(
                    .init(headers: headers, endStream: false)
                )
                streamChannel.writeAndFlush(frame, promise: nil)
            }
        }
    }

    private func markDataChannel(_ channel: Channel) {
        stateLock.sync { dataChannel = channel }
        state = .connected
        emit("data channel ready")
    }

    private func handleStreamClosed(reason: String) {
        emit("stream closed: \(reason)")
        markFailed("stream closed: \(reason)")
    }

    /// Connection-level loss (parent channel closeFuture resolved). This
    /// fires whether or not the per-stream handler saw events — covers
    /// abrupt TCP RST, TLS alert, Wi-Fi switch on the peer side, etc.
    /// `DirectChannel` listens to state changes and tears down the P2P
    /// route so `ContextTransport` falls back to SFU broadcast on the
    /// next send.
    private func handleConnectionLost(reason: String) {
        emit("connection lost: \(reason)")
        // Tear down the data channel and any pending state so subsequent
        // sends fail fast (allChannelsUnavailable → broadcast fallback).
        stateLock.sync {
            dataChannel = nil
        }
        markFailed("connection lost: \(reason)")
    }

    private func markFailed(_ reason: String) {
        // Idempotent: once we're closed/failed, don't bounce back through.
        switch state {
            case .closed, .failed:
                return
            default:
                state = .failed(reason)
        }
    }

    private func emit(_ message: String) {
        onLog?(message)
    }

    // MARK: - TLS contexts

    private static func makeServerTLSContext() throws -> NIOSSLContext {
        // Per-session self-signed cert: every listener presents a unique
        // P-256 cert generated in-process; private key never touches
        // disk. See P2PSessionIdentity and DESIGN_P2P_TLS.md.
        let identity = try P2PSessionIdentity.make()
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(identity.certificate)],
            privateKey: .privateKey(identity.privateKey)
        )
        config.applicationProtocols = ["h2"]
        config.minimumTLSVersion = .tlsv12
        return try NIOSSLContext(configuration: config)
    }

    private static func makeClientTLSContext() throws -> NIOSSLContext {
        var config = TLSConfiguration.makeClientConfiguration()
        config.applicationProtocols = ["h2"]
        config.minimumTLSVersion = .tlsv12
        // Lab mode: peer-to-peer with the bundled self-signed cert. The
        // pubkey-bound trust model lives in the KT envelope crypto layer,
        // not in TLS.
        config.certificateVerification = .none
        return try NIOSSLContext(configuration: config)
    }

    public enum Error: Swift.Error, Sendable {
        case notConnected
    }
}

// MARK: - Per-stream handler (carries length-prefixed records)

/// Reads inbound DATA frames, accumulates them, and re-emits length-
/// prefixed records via `onMessage`. Writes are the responsibility of
/// the parent channel (the carrier does length-prefix framing on send).
private final class BlobStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    enum Role { case server, client }

    private let role: Role
    private let onMessage: (Data) -> Void
    private let onReady: (Channel) -> Void
    private let onClose: (String) -> Void
    private var buffer = Data()
    private var didEmitResponseHeaders = false

    init(
        role: Role,
        onMessage: @escaping (Data) -> Void,
        onReady: @escaping (Channel) -> Void,
        onClose: @escaping (String) -> Void
    ) {
        self.role = role
        self.onMessage = onMessage
        self.onReady = onReady
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        switch payload {
            case .headers(let h):
                if role == .server {
                    // Reply with response headers so the response stream opens.
                    sendResponseHeaders(context: context)
                    onReady(context.channel)
                } else {
                    // Initiator side: receipt of response headers signals the
                    // server-side stream is open. Carrier is now usable.
                    _ = h
                    onReady(context.channel)
                }
            case .data(let d):
                switch d.data {
                    case .byteBuffer(var buf):
                        let chunk = buf.readData(length: buf.readableBytes) ?? Data()
                        buffer.append(chunk)
                        drainBuffer()
                    case .fileRegion:
                        break
                }
                if d.endStream { context.close(promise: nil) }
            case .rstStream(let code):
                onClose("rst \(code)")
                context.close(promise: nil)
            case .goAway(let lastID, let code, _):
                onClose("goaway last=\(lastID) code=\(code)")
                context.close(promise: nil)
            default:
                break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose("inactive")
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onClose("error: \(error)")
        context.close(promise: nil)
    }

    private func sendResponseHeaders(context: ChannelHandlerContext) {
        guard !didEmitResponseHeaders else { return }
        didEmitResponseHeaders = true
        var headers = HPACKHeaders()
        headers.add(name: ":status", value: "200")
        headers.add(name: "content-type", value: "application/octet-stream")
        let frame = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: false))
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }

    private func drainBuffer() {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let recordLength = Int(length)
            guard buffer.count >= 4 + recordLength else { return }
            let payload = buffer.dropFirst(4).prefix(recordLength)
            buffer.removeFirst(4 + recordLength)
            onMessage(Data(payload))
        }
    }
}

private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

extension NSLock {
    @inline(__always)
    fileprivate func sync<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
