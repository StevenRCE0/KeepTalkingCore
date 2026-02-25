import Foundation

public enum KeepTalkingKVServiceError: Error {
    case invalidResponsePayload
    case invalidStoredValue
}

public final class KeepTalkingPassKVService: KeepTalkingKVService, @unchecked Sendable {
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

    // PassKeyValue API shapes.
    private struct KVEntry: Codable {
        let key: String
        let value: String
    }

    private struct KVGetResponse: Codable {
        let item: KVEntry
    }

    private struct KVUpsertRequest: Codable {
        let value: String
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = "\(intValue)"
            self.intValue = intValue
        }
    }

    private struct KVDocument: Codable, Sendable {
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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            var nodes: [String] = []
            var records: [String: NodeMetadata] = [:]
            var pairs: [String: String] = [:]

            for key in container.allKeys {
                if key.stringValue == KVDocumentKey.ownedNodes {
                    nodes = (try? container.decode([String].self, forKey: key)) ?? []
                    continue
                }
                if key.stringValue.hasPrefix(KVDocumentKey.Prefix.node.rawValue) {
                    if let record = try? container.decode(NodeMetadata.self, forKey: key) {
                        records[key.stringValue] = record
                    }
                    continue
                }
                if key.stringValue.hasPrefix(KVDocumentKey.Prefix.pair.rawValue) {
                    if let publicKey = try? container.decode(String.self, forKey: key) {
                        pairs[key.stringValue] = publicKey
                    }
                }
            }

            ktOwnedNodes = nodes
            nodeRecords = records
            pairPublicKeys = pairs
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            guard let ownedNodesKey = DynamicCodingKey(
                stringValue: KVDocumentKey.ownedNodes
            )
            else {
                return
            }
            try container.encode(ktOwnedNodes, forKey: ownedNodesKey)
            for (nodeKey, metadata) in nodeRecords {
                guard let codingKey = DynamicCodingKey(stringValue: nodeKey) else {
                    continue
                }
                try container.encode(metadata, forKey: codingKey)
            }
            for (pairKey, publicKey) in pairPublicKeys {
                guard let codingKey = DynamicCodingKey(stringValue: pairKey) else {
                    continue
                }
                try container.encode(publicKey, forKey: codingKey)
            }
        }
    }

    private let baseURL: URL
    private let kvPath: String
    private let documentKey: String
    private let session: URLSession
    private let defaultNodeName: String?
    private let defaultNodePurposes: [String]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        baseURL: URL,
        kvPath: String = "/api/kv",
        documentKey: String = "keep-talking",
        defaultNodeName: String? = nil,
        defaultNodePurposes: [String] = [],
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.kvPath = kvPath
        self.documentKey = documentKey
        self.defaultNodeName = defaultNodeName
        self.defaultNodePurposes = defaultNodePurposes
        self.session = session
    }

    // Backward-compatible initializer label.
    public convenience init(
        baseURL: URL,
        nodesPath: String,
        documentKey: String = "keep-talking",
        defaultNodeName: String? = nil,
        defaultNodePurposes: [String] = [],
        session: URLSession = .shared
    ) {
        self.init(
            baseURL: baseURL,
            kvPath: nodesPath,
            documentKey: documentKey,
            defaultNodeName: defaultNodeName,
            defaultNodePurposes: defaultNodePurposes,
            session: session
        )
    }

    public func storeNodeID(_ node: UUID, publicKey: String?) async throws {
        let nodeID = normalizedNodeID(node.uuidString)
        let name = normalizedName(defaultNodeName) ?? nodeID
        try await storeNodeMetadata(
            nodeID: nodeID,
            name: name,
            purposes: defaultNodePurposes,
            publicKey: publicKey
        )
    }

    public func loadNodeIDs() async throws -> [UUID] {
        let document = try await fetchDocument()
        return document.ktOwnedNodes.compactMap { UUID(uuidString: $0) }
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
        document.nodeRecords[nodeRecordKey(nodeID: normalizedID)] = NodeMetadata(
            name: normalizedName(name) ?? normalizedID,
            purposes: purposes
        )
        if let normalizedPublicKey = normalizedName(publicKey) {
            let normalizedTrustedID = normalizedNodeID(trustedNodeID ?? normalizedID)
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
        let rawID = String(key.dropFirst(KVDocumentKey.Prefix.node.rawValue.count))
        let nodeID = normalizedNodeID(rawID)
        return nodeID.isEmpty ? nil : nodeID
    }

    private func parsePairPublicKey(
        _ key: String
    ) -> (nodeID: String, trustedNodeID: String)? {
        guard key.hasPrefix(KVDocumentKey.Prefix.pair.rawValue) else {
            return nil
        }
        let rawPair = String(key.dropFirst(KVDocumentKey.Prefix.pair.rawValue.count))
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

    private func makeKVEntryURL() -> URL {
        makeURL(path: trimSlashes(kvPath))
            .appendingPathComponent(trimSlashes(documentKey), isDirectory: false)
    }

    private func fetchDocument() async throws -> KVDocument {
        var request = URLRequest(url: makeKVEntryURL())
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if http.statusCode == 404 {
            return KVDocument()
        }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        if data.isEmpty {
            return KVDocument()
        }

        let rawDocumentData: Data
        if let wrapped = try? decoder.decode(KVGetResponse.self, from: data) {
            guard let valueData = wrapped.item.value.data(using: .utf8) else {
                throw KeepTalkingKVServiceError.invalidStoredValue
            }
            rawDocumentData = valueData
        } else {
            // Legacy fallback for previous direct-document HTTP service.
            rawDocumentData = data
        }

        var document = try decodeDocument(rawDocumentData)
        document.ktOwnedNodes = normalizeOwnedNodes(document.ktOwnedNodes)
        document.nodeRecords = normalizeNodeRecords(document.nodeRecords)
        document.pairPublicKeys = normalizePairPublicKeys(document.pairPublicKeys)
        return document
    }

    private func saveDocument(_ document: KVDocument) async throws {
        var request = URLRequest(url: makeKVEntryURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let documentData = try encoder.encode(document)
        guard let documentJSON = String(data: documentData, encoding: .utf8) else {
            throw KeepTalkingKVServiceError.invalidStoredValue
        }
        request.httpBody = try encoder.encode(KVUpsertRequest(value: documentJSON))

        let (_, response) = try await session.data(for: request)
        try validateHTTP(response, expected: [200, 201])
    }

    private func decodeDocument(_ data: Data) throws -> KVDocument {
        if let document = try? decoder.decode(KVDocument.self, from: data) {
            return document
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
