import Foundation

public enum KeepTalkingKVServiceError: Error {
    case invalidResponsePayload
}

public final class KeepTalkingHTTPKVService: KeepTalkingKVService, @unchecked Sendable {
    private struct LegacyListResponse: Codable {
        let nodeIDs: [String]
    }

    private struct NodeMetadata: Codable, Sendable {
        let name: String
        let purposes: [String]
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

        init(
            ktOwnedNodes: [String] = [],
            nodeRecords: [String: NodeMetadata] = [:]
        ) {
            self.ktOwnedNodes = ktOwnedNodes
            self.nodeRecords = nodeRecords
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            var nodes: [String] = []
            var records: [String: NodeMetadata] = [:]

            for key in container.allKeys {
                if key.stringValue == "ktOwnedNodes" {
                    nodes = (try? container.decode([String].self, forKey: key)) ?? []
                    continue
                }
                guard key.stringValue.hasPrefix("ktNode-") else {
                    continue
                }
                if let record = try? container.decode(NodeMetadata.self, forKey: key) {
                    records[key.stringValue] = record
                }
            }

            ktOwnedNodes = nodes
            nodeRecords = records
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            guard let ownedNodesKey = DynamicCodingKey(stringValue: "ktOwnedNodes")
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
        }
    }

    private let baseURL: URL
    private let nodesPath: String
    private let session: URLSession
    private let defaultNodeName: String?
    private let defaultNodePurposes: [String]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        baseURL: URL,
        nodesPath: String = "/nodes",
        defaultNodeName: String? = nil,
        defaultNodePurposes: [String] = [],
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.nodesPath = nodesPath
        self.defaultNodeName = defaultNodeName
        self.defaultNodePurposes = defaultNodePurposes
        self.session = session
    }

    public func storeNodeID(_ node: UUID) async throws {
        let nodeID = normalizedNodeID(node.uuidString)
        let name = normalizedName(defaultNodeName) ?? nodeID
        try await storeNodeMetadata(nodeID: nodeID, name: name, purposes: defaultNodePurposes)
    }

    public func loadNodeIDs() async throws -> [UUID] {
        let document = try await fetchDocument()
        return document.ktOwnedNodes.compactMap { UUID(uuidString: $0) }
    }

    public func storeNodeMetadata(
        nodeID: String,
        name: String,
        purposes: [String]
    ) async throws {
        let normalizedID = normalizedNodeID(nodeID)
        guard !normalizedID.isEmpty else { return }

        var document = try await fetchDocument()
        if !document.ktOwnedNodes.contains(normalizedID) {
            document.ktOwnedNodes.append(normalizedID)
        }
        document.nodeRecords["ktNode-\(normalizedID)"] = NodeMetadata(
            name: normalizedName(name) ?? normalizedID,
            purposes: purposes
        )
        try await saveDocument(document)
    }

    // Backwards-compat shim: this now maps `userID` into the node metadata `name`.
    public func storeNodeID(_ nodeID: String, for userID: String) async throws {
        try await storeNodeMetadata(
            nodeID: nodeID,
            name: normalizedName(userID) ?? normalizedNodeID(nodeID),
            purposes: defaultNodePurposes
        )
    }

    // Backwards-compat shim: user-scoped fetch now returns the global owned node list.
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

    private func fetchDocument() async throws -> KVDocument {
        var request = URLRequest(url: makeURL(path: nodesPath))
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
        var document = try decodeDocument(data)
        document.ktOwnedNodes = normalizeOwnedNodes(document.ktOwnedNodes)
        return document
    }

    private func saveDocument(_ document: KVDocument) async throws {
        var request = URLRequest(url: makeURL(path: nodesPath))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(document)

        let (_, response) = try await session.data(for: request)
        try validateHTTP(response, expected: [200, 201, 204])
    }

    private func decodeDocument(_ data: Data) throws -> KVDocument {
        if let document = try? decoder.decode(KVDocument.self, from: data) {
            return document
        }
        if let wrapped = try? decoder.decode(LegacyListResponse.self, from: data) {
            return KVDocument(ktOwnedNodes: wrapped.nodeIDs)
        }
        if let legacyList = try? decoder.decode([String].self, from: data) {
            return KVDocument(ktOwnedNodes: legacyList)
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
