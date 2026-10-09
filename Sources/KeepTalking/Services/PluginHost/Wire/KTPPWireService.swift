//
//  KTPPWireService.swift
//  KeepTalking
//
//  KTPP v2 transport: gRPC over a Unix domain socket, JSON-coded (the
//  messages are in KTPPWireMessages.swift). Desktop builds only — the SDK
//  takes gRPC as a macOS/Linux-conditional dependency, so iOS and visionOS
//  never compile this file's body.
//
//  Service `keeptalking.plugin.v2.PluginHost`:
//    Connect        bidi   the plugin's connection: hello, kinds, and the
//                          host's calls to it with their answers
//    RequestAct     unary  plugin → host, one ACT turn for an in-flight call
//    ProposeAction  unary  plugin → host, ask the user to create an instance
//    OpenAddAction  unary  plugin → host, open the Add Action flow
//
//  gRPC owns the connection edge cases: an exiting peer closes the socket and
//  ends `Connect` at once, HTTP/2 keepalive ends a frozen one, the client
//  channel reconnects by itself, and failed unary calls surface as status
//  codes.
//

#if canImport(GRPCCore) && canImport(GRPCNIOTransportHTTP2Posix)

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix

// MARK: - Methods

extension KTPPWire {
    public enum Method {
        /// The gRPC service name; a method's path is `/<service>/<method>`.
        public static let service = "keeptalking.plugin.v2.PluginHost"

        public static let connect = MethodDescriptor(
            fullyQualifiedService: service, method: "Connect", type: .bidirectionalStreaming)
        public static let requestAct = MethodDescriptor(
            fullyQualifiedService: service, method: "RequestAct", type: .unary)
        public static let proposeAction = MethodDescriptor(
            fullyQualifiedService: service, method: "ProposeAction", type: .unary)
        public static let openAddAction = MethodDescriptor(
            fullyQualifiedService: service, method: "OpenAddAction", type: .unary)
    }
}

// MARK: - JSON codec

/// Messages travel as JSON. Fixed shapes are typed `Codable` models; free-form
/// payloads (JSON Schemas, MCP arguments, scope bags) stay nested JSON, and
/// integers stay integers.
public struct KTPPJSONSerializer<Message: Encodable>: MessageSerializer {
    public init() {}

    public func serialize<Bytes: GRPCContiguousBytes>(_ message: Message) throws -> Bytes {
        Bytes(try JSONEncoder().encode(message))
    }
}

public struct KTPPJSONDeserializer<Message: Decodable>: MessageDeserializer {
    public init() {}

    public func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws -> Message {
        try serializedMessageBytes.withUnsafeBytes { buffer in
            try JSONDecoder().decode(Message.self, from: Data(buffer))
        }
    }
}

// MARK: - Keepalive

extension KTPPWire {
    /// Both ends ping a quiet connection this often and drop it when a ping
    /// goes unanswered for `keepaliveTimeout`. Only a frozen peer needs this:
    /// an exit closes the socket and ends the connection immediately.
    static let keepaliveTime: Duration = .seconds(10)
    static let keepaliveTimeout: Duration = .seconds(5)

    /// Largest message a plugin may send (gRPC's default is 4 MiB): call
    /// results carry screenshots and documents.
    static let maxPluginMessageBytes = 64 * 1024 * 1024

    static func serverConfig() -> HTTP2ServerTransport.Posix.Config {
        .defaults { config in
            config.rpc.maxRequestPayloadSize = maxPluginMessageBytes
            // gRPC's server default refuses client pings more often than every
            // five minutes and outside calls, then closes the connection for
            // "too many pings". Plugins keep their own keepalive, so allow it.
            config.connection.keepalive = .init(
                time: keepaliveTime,
                timeout: keepaliveTimeout,
                clientBehavior: .init(
                    minPingIntervalWithoutCalls: keepaliveTime / 2,
                    allowWithoutCalls: true))
        }
    }

    static func clientConfig() -> HTTP2ClientTransport.Posix.Config {
        .defaults { config in
            config.connection.keepalive = .init(
                time: keepaliveTime, timeout: keepaliveTimeout, allowWithoutCalls: true)
        }
    }
}

// MARK: - Host side

/// What the host implements to serve `PluginHost`.
public protocol KTPPWireHostHandler: Sendable {
    /// One plugin's connection, for as long as it stays open. Read the
    /// plugin's messages from `inbound` and write to `outbound`; `inbound`
    /// ends (or throws) when the plugin goes away, and returning ends it.
    func connect(
        inbound: RPCAsyncSequence<KTPPWire.PluginMessage, any Error>,
        outbound: RPCWriter<KTPPWire.HostMessage>,
        context: ServerContext
    ) async throws

    func requestAct(_ request: KTPPActRequest, context: ServerContext) async throws -> KTPPActResult

    func proposeAction(
        _ request: KTPPActionCreateRequest, context: ServerContext
    ) async throws -> KTPPActionCreateResult

    func openAddAction(
        _ request: KTPPUIAddActionRequest, context: ServerContext
    ) async throws -> KTPPWire.Empty
}

struct KTPPWireHostService<Handler: KTPPWireHostHandler>: RegistrableRPCService {
    let handler: Handler

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        let handler = self.handler
        router.registerHandler(
            forMethod: KTPPWire.Method.connect,
            deserializer: KTPPJSONDeserializer<KTPPWire.PluginMessage>(),
            serializer: KTPPJSONSerializer<KTPPWire.HostMessage>()
        ) { request, context in
            StreamingServerResponse { outbound in
                try await handler.connect(
                    inbound: request.messages, outbound: outbound, context: context)
                return [:]
            }
        }
        Self.registerUnary(KTPPWire.Method.requestAct, with: &router) {
            try await handler.requestAct($0, context: $1)
        }
        Self.registerUnary(KTPPWire.Method.proposeAction, with: &router) {
            try await handler.proposeAction($0, context: $1)
        }
        Self.registerUnary(KTPPWire.Method.openAddAction, with: &router) {
            try await handler.openAddAction($0, context: $1)
        }
    }

    private static func registerUnary<Input: Codable & Sendable, Output: Codable & Sendable, Transport>(
        _ method: MethodDescriptor,
        with router: inout RPCRouter<Transport>,
        _ body: @escaping @Sendable (Input, ServerContext) async throws -> Output
    ) {
        router.registerHandler(
            forMethod: method,
            deserializer: KTPPJSONDeserializer<Input>(),
            serializer: KTPPJSONSerializer<Output>()
        ) { request, context in
            let single = try await ServerRequest(stream: request)
            let output = try await body(single.message, context)
            return StreamingServerResponse(single: ServerResponse(message: output))
        }
    }
}

/// The host's listener: `PluginHost` served on a Unix domain socket. A stale
/// socket file from a crashed run is replaced on bind. The socket's
/// directory is the access gate — the host binds inside one only the user can
/// reach.
public final class KTPPWireServer: Sendable {
    public let socketPath: String
    private let transport: HTTP2ServerTransport.Posix
    private let server: GRPCServer<HTTP2ServerTransport.Posix>

    public init(socketPath: String, handler: some KTPPWireHostHandler) {
        self.socketPath = socketPath
        transport = HTTP2ServerTransport.Posix(
            address: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext,
            config: KTPPWire.serverConfig())
        server = GRPCServer(transport: transport, services: [KTPPWireHostService(handler: handler)])
    }

    /// Serves until `beginGracefulShutdown()` (or an error); run it in a task.
    public func serve() async throws {
        try await server.serve()
    }

    /// Resolves once the socket is bound — the moment plugins can connect.
    public func waitUntilListening() async throws {
        _ = try await transport.listeningAddress
    }

    public func beginGracefulShutdown() {
        server.beginGracefulShutdown()
    }
}

// MARK: - Plugin side (Swift)

/// A Swift client of `PluginHost`, for the Companion app and tests. Python
/// plugins use grpcio with the same method paths and JSON bodies.
public final class KTPPWireClient: Sendable {
    private let client: GRPCClient<HTTP2ClientTransport.Posix>

    public init(socketPath: String) throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext,
            config: KTPPWire.clientConfig())
        client = GRPCClient(transport: transport)
    }

    /// Maintains the connection (reconnecting as needed) until
    /// `beginGracefulShutdown()`; run it in a task beside the calls.
    public func runConnections() async throws {
        try await client.runConnections()
    }

    public func beginGracefulShutdown() {
        client.beginGracefulShutdown()
    }

    /// Connects as a plugin. `outbound` writes the plugin's messages,
    /// starting with `hello`; returning from it ends the plugin's side.
    /// `inbound` reads the host's messages until the connection ends. With the
    /// default `waitForReady` the call waits for the host instead of failing
    /// while it is away.
    public func connect<Result: Sendable>(
        options: CallOptions = .waitingForHost,
        outbound: @escaping @Sendable (RPCWriter<KTPPWire.PluginMessage>) async throws -> Void,
        inbound:
            @escaping @Sendable (RPCAsyncSequence<KTPPWire.HostMessage, any Error>) async throws
            -> Result
    ) async throws -> Result {
        try await client.bidirectionalStreaming(
            request: StreamingClientRequest(producer: outbound),
            descriptor: KTPPWire.Method.connect,
            serializer: KTPPJSONSerializer<KTPPWire.PluginMessage>(),
            deserializer: KTPPJSONDeserializer<KTPPWire.HostMessage>(),
            options: options
        ) { response in
            try await inbound(response.messages)
        }
    }

    public func requestAct(
        _ request: KTPPActRequest, options: CallOptions = .defaults
    ) async throws -> KTPPActResult {
        try await unary(KTPPWire.Method.requestAct, request, options: options)
    }

    public func proposeAction(
        _ request: KTPPActionCreateRequest, options: CallOptions = .defaults
    ) async throws -> KTPPActionCreateResult {
        try await unary(KTPPWire.Method.proposeAction, request, options: options)
    }

    public func openAddAction(
        _ request: KTPPUIAddActionRequest, options: CallOptions = .defaults
    ) async throws {
        let _: KTPPWire.Empty = try await unary(KTPPWire.Method.openAddAction, request, options: options)
    }

    private func unary<Input: Codable & Sendable, Output: Codable & Sendable>(
        _ method: MethodDescriptor, _ input: Input, options: CallOptions
    ) async throws -> Output {
        try await client.unary(
            request: ClientRequest(message: input),
            descriptor: method,
            serializer: KTPPJSONSerializer<Input>(),
            deserializer: KTPPJSONDeserializer<Output>(),
            options: options
        ) { response in
            try response.message
        }
    }
}

extension CallOptions {
    /// Waits for the host to be reachable instead of failing fast.
    public static var waitingForHost: CallOptions {
        var options = CallOptions.defaults
        options.waitForReady = true
        return options
    }
}

#endif
