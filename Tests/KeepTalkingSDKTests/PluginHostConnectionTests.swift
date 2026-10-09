import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

#if canImport(GRPCCore) && canImport(GRPCNIOTransportHTTP2Posix)
import GRPCCore

/// The KTPP v2 host end to end, with a Swift client standing in for a plugin:
/// connecting, kind registration, a call through an injected attestor,
/// replacement by a newer copy, and ACT refusals. (The Python SDK's side is covered by
/// PluginSocketE2ETests.)
@Suite(.serialized)
struct PluginHostConnectionTests {

    /// A fake plugin on one connection: says hello, pushes one kind, and answers
    /// calls with a receipt bound to the invocation.
    private struct FakePlugin {
        let task: Task<Void, Error>
        /// Every host message, as a short label ("welcome", "call", "goodbye:superseded").
        let seen: AsyncInbox<String>
        let calls: AsyncInbox<KTPPCallRequest>
        let welcomes: AsyncInbox<KTPPWire.Welcome>
    }

    private static func connectPlugin(
        _ client: KTPPWireClient, name: String, instance: String
    ) -> FakePlugin {
        let (seen, seenSink) = AsyncStream.makeStream(of: String.self)
        let (calls, callSink) = AsyncStream.makeStream(of: KTPPCallRequest.self)
        let (replies, replySink) = AsyncStream.makeStream(of: KTPPWire.PluginMessage.self)
        let (welcomes, welcomeSink) = AsyncStream.makeStream(of: KTPPWire.Welcome.self)
        let task = Task {
            try await client.connect(
                outbound: { writer in
                    try await writer.write(
                        KTPPWire.PluginMessage(
                            body: .hello(
                                KTPPWire.Hello(
                                    name: name, vendor: "test", version: "1",
                                    role: .plugin, instance: instance))))
                    try await writer.write(
                        KTPPWire.PluginMessage(
                            body: .kinds(
                                KTPPKindsResult(
                                    manifestVersion: "1", manifestHash: "sha256:x",
                                    kinds: [
                                        KTPPKindDeclaration(
                                            kindName: "echo", displayName: "Echo",
                                            indexDescription: "Echoes", inputSchema: nil,
                                            scopeSchema: nil, defaultScope: nil, subTools: nil,
                                            objects: nil, capabilities: nil,
                                            remoteAuthorisable: nil, blockingAuthorisation: nil)
                                    ],
                                    meters: [KTPPMeterDeclaration(name: "chars", quantum: "1")]))))
                    for await reply in replies {
                        try await writer.write(reply)
                    }
                },
                inbound: { messages in
                    for try await message in messages {
                        switch message.body {
                            case .welcome(let welcome):
                                seenSink.yield("welcome")
                                welcomeSink.yield(welcome)
                            case .call(let call):
                                seenSink.yield("call")
                                callSink.yield(call)
                                replySink.yield(
                                    KTPPWire.PluginMessage(
                                        replyTo: message.id,
                                        body: .callResult(
                                            KTPPCallResult(
                                                requestID: call.requestID,
                                                content: .array([
                                                    .object(["type": .string("text"), "text": .string("echo")])
                                                ]),
                                                isError: false,
                                                usage: [KTPPMeterUsage(meter: "chars", units: 4)],
                                                receipt: KeepTalkingAttestation(
                                                    scheme: "test", payload: .string("r-\(call.requestID)"))))))
                            case .goodbye(let goodbye):
                                seenSink.yield("goodbye:\(goodbye.reason.rawValue)")
                            default:
                                seenSink.yield("other")
                        }
                    }
                    seenSink.yield("ended")
                    replySink.finish()
                })
        }
        return FakePlugin(
            task: task, seen: AsyncInbox(seen), calls: AsyncInbox(calls),
            welcomes: AsyncInbox(welcomes))
    }

    @Test("a plugin connects, pushes kinds, serves an attested call, and is replaced by a newer copy")
    func connectCallAndReplace() async throws {
        let socketPath = "/tmp/ktpp-host-\(UUID().uuidString.prefix(8)).sock"
        let attestor = RecordingAttestor()
        let host = KeepTalkingPluginHost(
            hostNodeID: UUID.v7(), socketPath: socketPath,
            catalogue: KeepTalkingPluginCatalogueStore(fileURL: nil), attestor: attestor)
        try await host.start()
        defer { Task { await host.stop() } }

        let client = try KTPPWireClient(socketPath: socketPath)
        let connections = Task { try await client.runConnections() }
        defer { connections.cancel() }

        let first = Self.connectPlugin(client, name: "echo-plugin", instance: "i1")
        #expect(await first.seen.next() == "welcome")
        let catalogID = try await host.waitForKind("echo", timeout: 10)
        #expect(catalogID == KeepTalkingPluginCatalogueStore.derivedCatalogID(pluginName: "echo-plugin"))
        #expect(await host.catalogue.isConnected(catalogID))

        let outcome = try await host.callKind(
            catalogID: catalogID, kindName: "echo", arguments: ["text": .string("echo")],
            instanceID: UUID.v7(), instanceScope: .object(["dir": .string("/tmp")]))
        #expect(!outcome.isError)
        #expect(outcome.usage == [KTPPMeterUsage(meter: "chars", units: 4)])
        #expect(outcome.record.verdict == .verified)

        // The attestor saw the call's facts, and its evidence rode the call.
        let sent = try #require(await first.calls.next())
        #expect(sent.authorization == KeepTalkingAttestation(scheme: "test", payload: .string("a-\(sent.requestID)")))
        let statement = try #require(await attestor.lastStatement)
        #expect(statement.invocationID == sent.requestID)
        #expect(statement.executorID == catalogID)
        #expect(statement.scope == .object(["dir": .string("/tmp")]))

        // A second copy with the same name takes over; the first is told not
        // to come back, and its stream ends.
        #expect(await first.seen.next() == "call")
        let second = Self.connectPlugin(client, name: "echo-plugin", instance: "i2")
        #expect(await second.seen.next() == "welcome")
        #expect(await first.seen.next() == "goodbye:superseded")
        #expect(await first.seen.next() == "ended")
        #expect(await host.catalogue.isConnected(catalogID))
        second.task.cancel()
    }

    @Test("RequestAct outside an in-flight call is refused with failedPrecondition and act_unbound")
    func actRefusals() async throws {
        let socketPath = "/tmp/ktpp-host-\(UUID().uuidString.prefix(8)).sock"
        let host = KeepTalkingPluginHost(
            hostNodeID: UUID.v7(), socketPath: socketPath,
            catalogue: KeepTalkingPluginCatalogueStore(fileURL: nil))
        try await host.start()
        defer { Task { await host.stop() } }
        let client = try KTPPWireClient(socketPath: socketPath)
        let connections = Task { try await client.runConnections() }
        defer { connections.cancel() }

        let act = KTPPActRequest(
            requestID: "nope", task: "t", system: nil, attachments: nil, expects: nil,
            maxOutputTokens: nil)
        let plugin = Self.connectPlugin(client, name: "act-plugin", instance: "i1")
        #expect(await plugin.welcomes.next() != nil)
        _ = try await host.waitForKind("echo", timeout: 10)
        do {
            _ = try await client.requestAct(act)
            Issue.record("an unbound ACT turn must be refused")
        } catch let error as RPCError {
            #expect(error.code == .failedPrecondition)
            #expect(Array(error.metadata[stringValues: "ktpp-code"]) == ["act_unbound"])
        }
        plugin.task.cancel()
    }
}

/// Authorizes every call with evidence naming the invocation and verifies the
/// fake plugin's matching receipt.
private actor RecordingAttestor: KeepTalkingCallAttestor {
    private(set) var lastStatement: KeepTalkingCallStatement?

    func authorize(_ statement: KeepTalkingCallStatement) async throws -> KeepTalkingAttestation? {
        lastStatement = statement
        return KeepTalkingAttestation(scheme: "test", payload: .string("a-\(statement.invocationID)"))
    }

    func verify(
        receipt: KeepTalkingAttestation?,
        result: KeepTalkingCallResultStatement,
        statement: KeepTalkingCallStatement,
        authorization: KeepTalkingAttestation?
    ) async -> KeepTalkingAttestationVerdict {
        guard authorization != nil,
            receipt == KeepTalkingAttestation(scheme: "test", payload: .string("r-\(statement.invocationID)"))
        else { return .rejected(reason: "receipt does not match the call") }
        return .verified
    }
}

#endif
