import Foundation

public enum KeepTalkingKVServiceError: Error {
    case invalidResponsePayload
    case invalidStoredValue
}

public struct KeepTalkingPairPublicKeyRecord: Sendable {
    public let sourceNodeID: UUID
    public let trustedNodeID: UUID
    public let publicKey: String

    public init(sourceNodeID: UUID, trustedNodeID: UUID, publicKey: String) {
        self.sourceNodeID = sourceNodeID
        self.trustedNodeID = trustedNodeID
        self.publicKey = publicKey
    }
}

public final class KeepTalkingPassKVService: KeepTalkingKVService,
    @unchecked Sendable
{
    private enum KVDocumentKey {
        static let ownedNodes = "ktOwnedNodes"

        enum Prefix: String {
            case node = "ktNode-"
            case pair = "ktPair-"
        }
    }

    private struct NodeMetadata: Codable, Sendable {
        let name: String
        let purposes: [String]
    }

    // PassKeyValue API shapes from PassKeyValue/README.md.
    private struct KVEntry: Codable {
        let key: String
        let value: String
    }

    private struct KVListResponse: Codable {
        let items: [KVEntry]
    }

    private struct KVUpsertRequest: Codable {
        let value: String
    }

    private struct KVUpsertResponse: Codable {
        let item: KVEntry
    }

    private struct KVDocument: Sendable {
        var ktOwnedNodes: [String]
        var nodeRecords: [String: NodeMetadata]
        var pairPublicKeys: [String: String]

        init(
            ktOwnedNodes: [String] = [],
            nodeRecords: [String: NodeMetadata] = [:],
            pairPublicKeys: [String: String] = [:]
        ) {
            self.ktOwnedNodes = ktOwnedNodes
            self.nodeRecords = nodeRecords
            self.pairPublicKeys = pairPublicKeys
        }
    }

    private let baseURL: URL
    private let kvPath: String
    private let session: URLSession
    private let defaultNodeName: String?
    private let defaultNodePurposes: [String]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        baseURL: URL,
        kvPath: String = "/api/kv",
        defaultNodeName: String? = nil,
        defaultNodePurposes: [String] = [],
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.kvPath = kvPath
        self.defaultNodeName = defaultNodeName
        self.defaultNodePurposes = defaultNodePurposes
        self.session = session
    }

    // Backward-compatible initializer label.
    public convenience init(
        baseURL: URL,
        nodesPath: String,
        defaultNodeName: String? = nil,
        defaultNodePurposes: [String] = [],
        session: URLSession = .shared
    ) {
        self.init(
            baseURL: baseURL,
            kvPath: nodesPath,
            defaultNodeName: defaultNodeName,
            defaultNodePurposes: defaultNodePurposes,
            session: session
        )
    }

    public func storeNodeID(_ node: UUID) async throws {
        let nodeID = normalizedNodeID(node.uuidString)
        let name = normalizedName(defaultNodeName) ?? nodeID
        try await storeNodeMetadata(
            nodeID: nodeID,
            name: name,
            purposes: defaultNodePurposes
        )
    }

    public func loadNodeIDs() async throws -> [UUID] {
        let document = try await fetchDocument()
        return document.ktOwnedNodes.compactMap { UUID(uuidString: $0) }
    }

    public func loadPairPublicKeys(
        trustedNodeID: UUID? = nil
    ) async throws -> [KeepTalkingPairPublicKeyRecord] {
        let document = try await fetchDocument()
        let normalizedTrustedNodeID = trustedNodeID?
            .uuidString
            .lowercased()

        return document.pairPublicKeys.compactMap { key, publicKey in
            guard
                let pair = parsePairPublicKey(key),
                let sourceNodeID = UUID(uuidString: pair.nodeID),
                let pairTrustedNodeID = UUID(uuidString: pair.trustedNodeID)
            else {
                return nil
            }

            if let normalizedTrustedNodeID,
                pair.trustedNodeID != normalizedTrustedNodeID
            {
                return nil
            }

            return KeepTalkingPairPublicKeyRecord(
                sourceNodeID: sourceNodeID,
                trustedNodeID: pairTrustedNodeID,
                publicKey: publicKey
            )
        }
        .sorted {
            if $0.sourceNodeID == $1.sourceNodeID {
                return $0.trustedNodeID.uuidString < $1.trustedNodeID.uuidString
            }
            return $0.sourceNodeID.uuidString < $1.sourceNodeID.uuidString
        }
    }

    public func storeNodeMetadata(
        nodeID: String,
        name: String,
        purposes: [String],
        publicKey: String? = nil,
        trustedNodeID: String? = nil
    ) async throws {
        let normalizedID = normalizedNodeID(nodeID)
        guard !normalizedID.isEmpty else { return }

        var document = try await fetchDocument()
        if !document.ktOwnedNodes.contains(normalizedID) {
            document.ktOwnedNodes.append(normalizedID)
        }

        document.nodeRecords[nodeRecordKey(nodeID: normalizedID)] =
            NodeMetadata(
                name: normalizedName(name) ?? normalizedID,
                purposes: purposes
            )

        if let normalizedPublicKey = normalizedName(publicKey) {
            guard let trustedNodeID = trustedNodeID else {
                try await saveDocument(document)
                return
            }

            let normalizedTrustedID = normalizedNodeID(trustedNodeID)
            guard !normalizedTrustedID.isEmpty else {
                try await saveDocument(document)
                return
            }

            document.pairPublicKeys[
                pairPublicKey(
                    nodeID: normalizedID,
                    trustedNodeID: normalizedTrustedID
                )
            ] = normalizedPublicKey
        }

        try await saveDocument(document)
    }

    public func mintPushWakeHandles(
        token: String,
        topic: String,
        environment: String,
        scopes: [KeepTalkingPushWakeMintScope]
    ) async throws -> [KeepTalkingPushWakeHandle] {
        let payload = KeepTalkingPushWakeMintRequest(
            token: token,
            topic: topic,
            environment: environment,
            scopes: scopes
        )
        let response: KeepTalkingPushWakeMintResponse = try await postJSON(
            path: "/api/apn/mint",
            payload: payload
        )
        return response.handles
    }

    public func sendPushWake(
        handle: KeepTalkingPushWakeHandle,
        contextEnvelope: KeepTalkingPushWakeContextEnvelope? = nil,
        actionEnvelope: KeepTalkingPushWakeActionEnvelope? = nil
    ) async throws -> KeepTalkingPushWakeSendResponse {
        try await postJSON(
            path: "/api/apn/send",
            payload: KeepTalkingPushWakeSendRequest(
                handle: handle,
                contextEnvelope: contextEnvelope,
                actionEnvelope: actionEnvelope
            )
        )
    }

    // Backwards-compat shim.
    public func storeNodeID(_ nodeID: String, for userID: String) async throws {
        try await storeNodeMetadata(
            nodeID: nodeID,
            name: normalizedName(userID) ?? normalizedNodeID(nodeID),
            purposes: defaultNodePurposes,
            publicKey: nil
        )
    }

    // Backwards-compat shim.
    public func loadNodeIDs(for userID: String) async throws -> [String] {
        _ = userID
        return try await fetchDocument().ktOwnedNodes
    }

    private func makeURL(path: String) -> URL {
        baseURL.appendingPathComponent(trimSlashes(path), isDirectory: false)
    }

    private func trimSlashes(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func normalizedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedNodeID(_ nodeID: String) -> String {
        nodeID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizeOwnedNodes(_ nodeIDs: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for nodeID in nodeIDs {
            let cleaned = normalizedNodeID(nodeID)
            guard !cleaned.isEmpty else { continue }
            if seen.insert(cleaned).inserted {
                normalized.append(cleaned)
            }
        }

        return normalized
    }

    private func normalizeNodeRecords(
        _ nodeRecords: [String: NodeMetadata]
    ) -> [String: NodeMetadata] {
        var normalized: [String: NodeMetadata] = [:]
        for (key, metadata) in nodeRecords {
            guard let nodeID = nodeIDFromNodeRecordKey(key) else { continue }
            normalized[nodeRecordKey(nodeID: nodeID)] = NodeMetadata(
                name: normalizedName(metadata.name) ?? nodeID,
                purposes: metadata.purposes
            )
        }
        return normalized
    }

    private func normalizePairPublicKeys(
        _ pairPublicKeys: [String: String]
    ) -> [String: String] {
        var normalized: [String: String] = [:]
        for (key, publicKey) in pairPublicKeys {
            guard
                let publicKey = normalizedName(publicKey),
                let pair = parsePairPublicKey(key)
            else {
                continue
            }
            normalized[
                pairPublicKey(
                    nodeID: pair.nodeID,
                    trustedNodeID: pair.trustedNodeID
                )
            ] = publicKey
        }
        return normalized
    }

    private func nodeRecordKey(nodeID: String) -> String {
        "\(KVDocumentKey.Prefix.node.rawValue)\(nodeID)"
    }

    private func pairPublicKey(nodeID: String, trustedNodeID: String) -> String {
        "\(KVDocumentKey.Prefix.pair.rawValue)\(nodeID):\(trustedNodeID)"
    }

    private func nodeIDFromNodeRecordKey(_ key: String) -> String? {
        guard key.hasPrefix(KVDocumentKey.Prefix.node.rawValue) else {
            return nil
        }
        let rawID = String(
            key.dropFirst(KVDocumentKey.Prefix.node.rawValue.count)
        )
        let nodeID = normalizedNodeID(rawID)
        return nodeID.isEmpty ? nil : nodeID
    }

    private func parsePairPublicKey(
        _ key: String
    ) -> (nodeID: String, trustedNodeID: String)? {
        guard key.hasPrefix(KVDocumentKey.Prefix.pair.rawValue) else {
            return nil
        }
        let rawPair = String(
            key.dropFirst(KVDocumentKey.Prefix.pair.rawValue.count)
        )
        let parts = rawPair.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else { return nil }
        let nodeID = normalizedNodeID(String(parts[0]))
        let trustedNodeID = normalizedNodeID(String(parts[1]))
        guard !nodeID.isEmpty, !trustedNodeID.isEmpty else {
            return nil
        }
        return (nodeID, trustedNodeID)
    }

    private func makeKVCollectionURL() -> URL {
        makeURL(path: trimSlashes(kvPath))
    }

    private func makeKVEntryURL(key: String) throws -> URL {
        guard let normalizedKey = normalizedName(key) else {
            throw KeepTalkingKVServiceError.invalidStoredValue
        }
        return makeKVCollectionURL()
            .appendingPathComponent(normalizedKey, isDirectory: false)
    }

    private func fetchDocument() async throws -> KVDocument {
        var request = URLRequest(url: makeKVCollectionURL())
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard !data.isEmpty else {
            return KVDocument()
        }

        let list = try decodeListResponse(data)
        var document = KVDocument()

        for item in list.items {
            if item.key == KVDocumentKey.ownedNodes {
                guard let valueData = item.value.data(using: .utf8) else {
                    continue
                }
                if let ownedNodes = try? decoder.decode(
                    [String].self,
                    from: valueData
                ) {
                    document.ktOwnedNodes = ownedNodes
                }
                continue
            }

            if item.key.hasPrefix(KVDocumentKey.Prefix.node.rawValue) {
                guard let valueData = item.value.data(using: .utf8) else {
                    continue
                }
                if let metadata = try? decoder.decode(
                    NodeMetadata.self,
                    from: valueData
                ) {
                    document.nodeRecords[item.key] = metadata
                }
                continue
            }

            if item.key.hasPrefix(KVDocumentKey.Prefix.pair.rawValue),
                let publicKey = normalizedName(item.value)
            {
                document.pairPublicKeys[item.key] = publicKey
            }
        }

        document.ktOwnedNodes = normalizeOwnedNodes(document.ktOwnedNodes)
        document.nodeRecords = normalizeNodeRecords(document.nodeRecords)
        document.pairPublicKeys = normalizePairPublicKeys(
            document.pairPublicKeys
        )
        return document
    }

    private func saveDocument(_ document: KVDocument) async throws {
        let ownedNodesJSON = try encodeJSONString(
            normalizeOwnedNodes(document.ktOwnedNodes)
        )
        try await upsertValue(ownedNodesJSON, forKey: KVDocumentKey.ownedNodes)

        let normalizedRecords = normalizeNodeRecords(document.nodeRecords)
        for (key, metadata) in normalizedRecords {
            let metadataJSON = try encodeJSONString(metadata)
            try await upsertValue(metadataJSON, forKey: key)
        }

        let normalizedPairs = normalizePairPublicKeys(document.pairPublicKeys)
        for (key, publicKey) in normalizedPairs {
            try await upsertValue(publicKey, forKey: key)
        }
    }

    private func upsertValue(_ value: String, forKey key: String) async throws {
        var request = URLRequest(url: try makeKVEntryURL(key: key))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(KVUpsertRequest(value: value))

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, expected: [200, 201])
        if !data.isEmpty {
            _ = try decodeUpsertResponse(data)
        }
    }

    private func encodeJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw KeepTalkingKVServiceError.invalidStoredValue
        }
        return json
    }

    private func postJSON<Payload: Encodable, Response: Decodable>(
        path: String,
        payload: Payload,
        expectedStatusCodes: [Int] = [200]
    ) async throws -> Response {
        var request = URLRequest(url: makeURL(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, expected: expectedStatusCodes)

        guard !data.isEmpty else {
            throw KeepTalkingKVServiceError.invalidResponsePayload
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw KeepTalkingKVServiceError.invalidResponsePayload
        }
    }

    private func decodeListResponse(_ data: Data) throws -> KVListResponse {
        if let response = try? decoder.decode(KVListResponse.self, from: data) {
            return response
        }
        throw KeepTalkingKVServiceError.invalidResponsePayload
    }

    private func decodeUpsertResponse(_ data: Data) throws -> KVUpsertResponse {
        if let response = try? decoder.decode(KVUpsertResponse.self, from: data) {
            return response
        }
        throw KeepTalkingKVServiceError.invalidResponsePayload
    }

    private func validateHTTP(_ response: URLResponse, expected: [Int]) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard expected.contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

@available(*, deprecated, renamed: "KeepTalkingPassKVService")
public typealias KeepTalkingHTTPKVService = KeepTalkingPassKVService
