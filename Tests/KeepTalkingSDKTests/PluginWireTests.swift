import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

#if canImport(GRPCCore) && canImport(GRPCNIOTransportHTTP2Posix)
import GRPCCore
#endif

/// KTPP: the JSON envelopes, and presence over the real gRPC transport on
/// a Unix domain socket. See Services/PluginHost/Wire.
struct PluginWireTests {

    // MARK: Envelopes

    @Test("envelopes encode flat with exactly one body key")
    func flatEnvelope() throws {
        let message = KTPPWire.PluginMessage(
            replyTo: 7,
            body: .reveal(KTPPWire.RevealResult(revealed: true)))
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        #expect(Set(object.keys) == ["replyTo", "reveal"])
        #expect(object["replyTo"] as? Int == 7)
    }

    @Test("a body from a newer peer decodes as unknown instead of failing the stream")
    func unknownBody() throws {
        let json = #"{"id": 3, "somethingNew": {"x": 1}}"#
        let message = try JSONDecoder().decode(KTPPWire.HostMessage.self, from: Data(json.utf8))
        #expect(message.id == 3)
        guard case .unknown = message.body else {
            Issue.record("expected .unknown, got \(message.body)")
            return
        }
    }

    @Test("unknown failure codes and goodbye reasons decode as unknown")
    func tolerantEnums() throws {
        let failure = try JSONDecoder().decode(
            KTPPWire.Failure.self, from: Data(#"{"code": "quotaExceeded", "message": "m"}"#.utf8))
        #expect(failure.code == .unknown)
        let goodbye = try JSONDecoder().decode(
            KTPPWire.Goodbye.self, from: Data(#"{"reason": "sleeping"}"#.utf8))
        #expect(goodbye.reason == .unknown)
    }

    // MARK: Transport

    #if canImport(GRPCCore) && canImport(GRPCNIOTransportHTTP2Posix)

    @Test("hello/welcome opens a connection, unary calls reach the host, and dropping it ends it at once")
    func connectionPresence() async throws {
        let socketPath = "/tmp/ktpp-test-\(UUID().uuidString.prefix(8)).sock"
        let (hostEvents, hostSink) = AsyncStream.makeStream(of: String.self)
        let (welcomes, welcomeSink) = AsyncStream.makeStream(of: KTPPWire.Welcome.self)
        let server = KTPPWireServer(socketPath: socketPath, handler: RecordingHost(events: hostSink))
        let serving = Task { try await server.serve() }
        defer {
            server.beginGracefulShutdown()
            serving.cancel()
        }
        try await server.waitUntilListening()

        let client = try KTPPWireClient(socketPath: socketPath)
        let connections = Task { try await client.runConnections() }
        defer { connections.cancel() }
        let hostEvent = AsyncInbox(hostEvents)
        let welcome = AsyncInbox(welcomes)

        // The connection stays open until the test drops it: the plugin's side
        // idles after hello, and its reader keeps reading after the welcome.
        let connection = Task {
            try await client.connect(
                outbound: { writer in
                    try await writer.write(
                        KTPPWire.PluginMessage(
                            body: .hello(
                                KTPPWire.Hello(
                                    name: "demo", vendor: "test", version: "1",
                                    role: .plugin, instance: "i1"))))
                    try await Task.sleep(for: .seconds(60))
                },
                inbound: { messages in
                    for try await message in messages {
                        if case .welcome(let value) = message.body { welcomeSink.yield(value) }
                    }
                })
        }

        #expect(await hostEvent.next() == "hello demo i1")
        let opened = try #require(await welcome.next())
        #expect(opened.instance == "h1")

        let act = try await client.requestAct(
            KTPPActRequest(
                requestID: "r1", task: "ping", system: nil, attachments: nil,
                expects: nil, maxOutputTokens: nil))
        #expect(act.text == "pong for r1")

        // Dropping the connection ends it on the host immediately — no
        // keepalive timeout involved. (A killed plugin process is covered end
        // to end by the Python SDK tests.)
        let dropped = ContinuousClock.now
        connection.cancel()
        #expect(await hostEvent.next() == "ended demo")
        #expect(ContinuousClock.now - dropped < .seconds(3))
    }

    #endif
}

#if canImport(GRPCCore) && canImport(GRPCNIOTransportHTTP2Posix)

/// Answers `Hello` with `Welcome`, echoes ACT turns, and reports what it saw.
private struct RecordingHost: KTPPWireHostHandler {
    let events: AsyncStream<String>.Continuation

    func connect(
        inbound: RPCAsyncSequence<KTPPWire.PluginMessage, any Error>,
        outbound: RPCWriter<KTPPWire.HostMessage>,
        context: ServerContext
    ) async throws {
        var name = "?"
        defer { events.yield("ended \(name)") }
        for try await message in inbound {
            if case .hello(let hello) = message.body {
                name = hello.name
                events.yield("hello \(hello.name) \(hello.instance)")
                try await outbound.write(
                    KTPPWire.HostMessage(
                        body: .welcome(KTPPWire.Welcome(hostNodeID: "node", instance: "h1"))))
            }
        }
    }

    func requestAct(_ request: KTPPActRequest, context: ServerContext) async throws -> KTPPActResult {
        KTPPActResult(text: "pong for \(request.requestID)", model: "test")
    }

    func proposeAction(
        _ request: KTPPActionCreateRequest, context: ServerContext
    ) async throws -> KTPPActionCreateResult {
        KTPPActionCreateResult(status: "unsupported", actionID: nil, message: nil)
    }

    func openAddAction(
        _ request: KTPPUIAddActionRequest, context: ServerContext
    ) async throws -> KTPPWire.Empty {
        KTPPWire.Empty()
    }
}

#endif
