import Foundation
import Testing

@testable import KeepTalkingSDK

@Suite(.serialized)
struct PassKVServiceTests {
    @Test("context push is sent while the recipient transport is still online")
    func contextPushDoesNotUseTransportLivenessAsVisibility() async throws {
        let fixture = try await ContextWakeFixture.make()
        _ = fixture.client.livenessState.observePresence(
            from: fixture.remoteNodeID,
            echoCooldown: 1
        )

        await fixture.client.sendContextWakeNotificationsIfNeeded(
            for: fixture.context,
            messagePreview: KeepTalkingPushWakeMessagePreview(
                sender: .autonomous(name: "ai", node: fixture.localNodeID),
                content: "Done",
                isTruncated: false
            )
        )

        #expect(await fixture.recorder.requests.map(\.path) == ["/api/apn/send"])
    }

    @Test("deleting a message sends a sealed revocation for the rows that raised a wake")
    func deletingMessageRevokesItsContextWake() async throws {
        let fixture = try await ContextWakeFixture.make()
        let messageID = UUID()
        let thinkingID = UUID()
        try await KeepTalkingContextMessage(
            id: messageID,
            context: fixture.context,
            sender: .node(node: fixture.localNodeID),
            content: "wrong chat",
            timestamp: Date(timeIntervalSince1970: 1)
        ).save(on: fixture.store.database)
        try await KeepTalkingContextMessage(
            id: thinkingID,
            context: fixture.context,
            sender: .autonomous(name: "ai", node: fixture.localNodeID),
            content: "pondering",
            timestamp: Date(timeIntervalSince1970: 2),
            type: .thinking
        ).save(on: fixture.store.database)

        try await fixture.client.deleteMessages([messageID, thinkingID], in: fixture.context.requireID())

        var attempts = 0
        while await fixture.recorder.requests.isEmpty, attempts < 100 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        let requests = await fixture.recorder.requests
        #expect(requests.map(\.path) == ["/api/apn/send"])
        let body = try #require(requests.first?.body)
        // PassKeyValue's `APNWakeSendRequest.Wake` decodes this same shape.
        let wire = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let wake = try #require(wire["wake"] as? [String: Any])
        #expect(Array(wake.keys) == ["revocation"])
        #expect((wake["revocation"] as? [String: Any])?["envelope"] != nil)
        let sent = try JSONDecoder().decode(KeepTalkingPushWakeSendRequest.self, from: body)
        guard case .revocation(let envelope) = sent.wake else {
            Issue.record("expected a revocation, sent \(sent.wake)")
            return
        }
        #expect(!envelope.ciphertext.contains(messageID.uuidString))
        #expect(
            try await KeepTalkingPushWakePreviewResolver.revokedMessageIDs(
                envelope,
                keychain: fixture.client.keychain
            ) == [messageID]
        )
    }

    @Test("deregister removes node and stale pair keys from PassKeyValue")
    func deregisterNodeIDRemovesOwnedNodeAndStaleKeys() async throws {
        let node = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let other = "00000000-0000-0000-0000-000000000002"
        let third = "00000000-0000-0000-0000-000000000003"
        let nodeID = node.uuidString.lowercased()

        let recorder = PassKVRequestRecorder()
        await recorder.setListResponse([
            ["key": "ktOwnedNodes", "value": "[\"\(nodeID)\",\"\(other)\"]"],
            ["key": "ktNode-\(nodeID)", "value": #"{"name":"node","purposes":[]}"#],
            ["key": "ktPair-\(nodeID):\(other)", "value": "node-to-other"],
            ["key": "ktPair-\(other):\(nodeID)", "value": "other-to-node"],
            ["key": "ktPair-\(other):\(third)", "value": "other-to-third"],
        ])

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PassKVURLProtocol.self]
        PassKVURLProtocol.recorder = recorder

        let service = KeepTalkingPassKVService(
            baseURL: try #require(URL(string: "https://passkv.test")),
            session: URLSession(configuration: config)
        )

        try await service.deregisterNodeID(node)

        let requests = await recorder.requests
        #expect(requests.map(\.method) == ["GET", "POST", "DELETE", "DELETE", "DELETE"])
        #expect(
            requests.map(\.path) == [
                "/api/kv",
                "/api/kv/ktOwnedNodes",
                "/api/kv/ktNode-\(nodeID)",
                "/api/kv/ktPair-\(nodeID):\(other)",
                "/api/kv/ktPair-\(other):\(nodeID)",
            ])
        #expect(requests[1].storedOwnedNodes == [other])
    }
}

/// A local node trusting one remote node with the context, whose device
/// holds a context wake handle, and a client whose PassKV requests are
/// recorded rather than sent.
private struct ContextWakeFixture {
    let localNodeID: UUID
    let remoteNodeID: UUID
    let context: KeepTalkingContext
    let store: KeepTalkingInMemoryStore
    let client: KeepTalkingClient
    let recorder: PassKVRequestRecorder

    static func make() async throws -> ContextWakeFixture {
        let localNodeID = UUID()
        let remoteNodeID = UUID()
        let contextID = UUID()
        let context = KeepTalkingContext(id: contextID)
        let localNode = KeepTalkingNode(id: localNodeID)
        let remoteNode = KeepTalkingNode(id: remoteNodeID)
        remoteNode.contextWakeHandles = [
            KeepTalkingPushWakeHandle(
                purpose: .contextMessage,
                contextID: contextID,
                opaqueValue: "context-handle",
                topic: "com.keeptalking.test",
                environment: "development"
            )
        ]

        let store = try await KeepTalkingInMemoryStore.make()
        try await context.save(on: store.database)
        try await localNode.save(on: store.database)
        try await remoteNode.save(on: store.database)
        try await KeepTalkingNodeRelation(
            from: localNode,
            to: remoteNode,
            relationship: .trusted([context])
        ).save(on: store.database)

        let recorder = PassKVRequestRecorder()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PassKVURLProtocol.self]
        PassKVURLProtocol.recorder = recorder
        let service = KeepTalkingPassKVService(
            baseURL: try #require(URL(string: "https://passkv.test")),
            session: URLSession(configuration: sessionConfiguration)
        )
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                contextID: contextID,
                node: localNodeID
            ),
            kvService: service,
            localStore: store
        )
        return ContextWakeFixture(
            localNodeID: localNodeID,
            remoteNodeID: remoteNodeID,
            context: context,
            store: store,
            client: client,
            recorder: recorder
        )
    }
}

private actor PassKVRequestRecorder {
    private(set) var requests: [RecordedPassKVRequest] = []
    private var listResponse: [[String: String]] = []

    func setListResponse(_ response: [[String: String]]) {
        listResponse = response
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let method = request.httpMethod ?? "GET"
        let url = try #require(request.url)
        requests.append(
            RecordedPassKVRequest(
                method: method,
                path: url.path,
                body: Self.bodyData(from: request)
            )
        )

        let status = method == "POST" ? 201 : 200
        let payload: [String: Any]
        if url.path == "/api/apn/send" {
            payload = ["accepted": true, "messageID": "push-id"]
        } else if method == "GET" {
            payload = ["items": listResponse]
        } else if method == "POST" {
            payload = ["item": ["key": url.lastPathComponent, "value": "[]"]]
        } else {
            payload = ["deletedKey": url.lastPathComponent, "present": [:]]
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )
        )
        return (response, data)
    }

    private nonisolated static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private struct RecordedPassKVRequest: Sendable {
    let method: String
    let path: String
    let body: Data?

    var storedOwnedNodes: [String]? {
        guard
            let body,
            let outer = try? JSONSerialization.jsonObject(with: body) as? [String: String],
            let value = outer["value"],
            let data = value.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}

private final class PassKVURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorder: PassKVRequestRecorder?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Task {
            do {
                let recorder = try #require(Self.recorder)
                let (response, data) = try await recorder.response(for: request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
