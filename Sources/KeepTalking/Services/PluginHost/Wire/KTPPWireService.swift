//
//  KTPPWireService.swift
//  KeepTalking
//
//  `keeptalking.plugin.Companion/Attach`: one bidi stream per KeepTalking
//  process, gRPC over the companion's Unix socket, JSON-coded. Desktop only.
//

#if canImport(GRPCCore) && canImport(GRPCNIOTransportHTTP2Posix)

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix

extension KTPPWire {
    static let attach = MethodDescriptor(
        fullyQualifiedService: "keeptalking.plugin.Companion", method: "Attach", type: .bidirectionalStreaming)
    static let maxMessageBytes = 64 * 1024 * 1024
}

struct KTPPJSONSerializer<Message: Encodable>: MessageSerializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: Message) throws -> Bytes {
        Bytes(try JSONEncoder().encode(message))
    }
}

struct KTPPJSONDeserializer<Message: Decodable>: MessageDeserializer {
    func deserialize<Bytes: GRPCContiguousBytes>(_ bytes: Bytes) throws -> Message {
        try bytes.withUnsafeBytes { try JSONDecoder().decode(Message.self, from: Data($0)) }
    }
}

final class KTPPWireClient: Sendable {
    private let client: GRPCClient<HTTP2ClientTransport.Posix>

    init(socketPath: String) throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext,
            config: .defaults { config in
                config.connection.keepalive = .init(time: .seconds(10), timeout: .seconds(5), allowWithoutCalls: true)
                // gRPC's two-minute ceiling would leave KeepTalking detached
                // long after the companion is back.
                config.backoff = .init(initial: .milliseconds(500), max: .seconds(3), multiplier: 1.6, jitter: 0.2)
            })
        client = GRPCClient(transport: transport)
    }

    func runConnections() async throws {
        try await client.runConnections()
    }

    func beginGracefulShutdown() {
        client.beginGracefulShutdown()
    }

    func attach(
        outbound: @escaping @Sendable (RPCWriter<KTPPWire.AppMessage>) async throws -> Void,
        inbound: @escaping @Sendable (RPCAsyncSequence<KTPPWire.CompanionMessage, any Error>) async throws -> Void
    ) async throws {
        var options = CallOptions.defaults
        options.waitForReady = true
        options.maxResponseMessageBytes = KTPPWire.maxMessageBytes
        try await client.bidirectionalStreaming(
            request: StreamingClientRequest(producer: outbound),
            descriptor: KTPPWire.attach,
            serializer: KTPPJSONSerializer<KTPPWire.AppMessage>(),
            deserializer: KTPPJSONDeserializer<KTPPWire.CompanionMessage>(),
            options: options
        ) { try await inbound($0.messages) }
    }
}

#endif
