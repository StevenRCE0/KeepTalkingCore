import Foundation
import Testing

@testable import KeepTalkingSDK

@Suite(.serialized)
struct PassKVServiceTests {
    @Test("context push is sent while the recipient transport is still online")
    func contextPushDoesNotUseTransportLivenessAsVisibility() async throws {
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
        _ = client.livenessState.observePresence(
            from: remoteNodeID,
            echoCooldown: 1
        )

        await client.sendContextWakeNotificationsIfNeeded(
            for: context,
            messagePreview: KeepTalkingPushWakeMessagePreview(
                sender: .autonomous(name: "ai", node: localNodeID),
                content: "Done",
                isTruncated: false
            )
        )

        #expect(await recorder.requests.map(\.path) == ["/api/apn/send"])
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
