import Foundation

public enum KeepTalkingBlobStoreError: LocalizedError {
    case invalidBlobID(String)
    case blobNotFound(String)

    public var errorDescription: String? {
        switch self {
            case .invalidBlobID(let blobID):
                return "Blob ID is invalid: \(blobID)"
            case .blobNotFound(let blobID):
                return "Blob is not available locally: \(blobID)"
        }
    }
}

public struct KeepTalkingBlobStore: Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public static func makeDefault(for localStore: any KeepTalkingLocalStore)
        -> KeepTalkingBlobStore
    {
        if let modelStore = localStore as? KeepTalkingModelStore {
            return KeepTalkingBlobStore(
                baseURL: modelStore.databaseURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("blobs", isDirectory: true)
            )
        }

        return KeepTalkingBlobStore(
            baseURL: URL(
                fileURLWithPath: NSTemporaryDirectory(),
                isDirectory: true
            )
            .appendingPathComponent("KeepTalking-Blobs", isDirectory: true)
        )
    }

    public func ensureBaseDirectory() throws {
        try FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true
        )
    }

    public func relativePath(
        for blobID: String,
        pathExtension: String? = nil
    ) throws -> String {
        let normalizedBlobID = try normalizedBlobID(blobID)
        let prefix = String(normalizedBlobID.prefix(2))
        let suffix = pathExtension?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let suffix, !suffix.isEmpty {
            return "\(prefix)/\(normalizedBlobID).\(suffix.lowercased())"
        }
        return "\(prefix)/\(normalizedBlobID)"
    }

    public func partialRelativePath(for blobID: String) throws -> String {
        let normalizedBlobID = try normalizedBlobID(blobID)
        let prefix = String(normalizedBlobID.prefix(2))
        return "partial/\(prefix)/\(normalizedBlobID).part"
    }

    public func fileURL(forRelativePath relativePath: String) -> URL {
        baseURL.appendingPathComponent(relativePath, isDirectory: false)
    }

    public func fileURL(
        for blobID: String,
        pathExtension: String? = nil
    ) throws -> URL {
        fileURL(
            forRelativePath: try relativePath(
                for: blobID,
                pathExtension: pathExtension
            )
        )
    }

    public func partialFileURL(for blobID: String) throws -> URL {
        fileURL(forRelativePath: try partialRelativePath(for: blobID))
    }

    @discardableResult
    public func put(
        data: Data,
        blobID: String,
        pathExtension: String? = nil
    ) throws -> (relativePath: String, fileURL: URL) {
        try ensureBaseDirectory()

        let relativePath = try relativePath(
            for: blobID,
            pathExtension: pathExtension
        )
        let fileURL = fileURL(forRelativePath: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
        }

        return (relativePath, fileURL)
    }

    public func read(relativePath: String?, blobID: String) throws -> Data {
        guard let relativePath else {
            throw KeepTalkingBlobStoreError.blobNotFound(blobID)
        }
        let fileURL = fileURL(forRelativePath: relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw KeepTalkingBlobStoreError.blobNotFound(blobID)
        }
        return try Data(contentsOf: fileURL)
    }

    @discardableResult
    public func appendPartial(
        data: Data,
        blobID: String,
        reset: Bool = false
    ) throws -> Int {
        try ensureBaseDirectory()

        let fileURL = try partialFileURL(for: blobID)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if reset, FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil
            )
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    public func partialData(blobID: String) throws -> Data {
        let fileURL = try partialFileURL(for: blobID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw KeepTalkingBlobStoreError.blobNotFound(blobID)
        }
        return try Data(contentsOf: fileURL)
    }

    @discardableResult
    public func promotePartial(
        blobID: String,
        pathExtension: String? = nil
    ) throws -> (relativePath: String, fileURL: URL) {
        try ensureBaseDirectory()

        let partialURL = try partialFileURL(for: blobID)
        guard FileManager.default.fileExists(atPath: partialURL.path) else {
            throw KeepTalkingBlobStoreError.blobNotFound(blobID)
        }

        let relativePath = try relativePath(
            for: blobID,
            pathExtension: pathExtension
        )
        let fileURL = fileURL(forRelativePath: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: partialURL)
            return (relativePath, fileURL)
        }

        try FileManager.default.moveItem(at: partialURL, to: fileURL)
        return (relativePath, fileURL)
    }

    public func removePartial(blobID: String) throws {
        let fileURL = try partialFileURL(for: blobID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func normalizedBlobID(_ blobID: String) throws -> String {
        let normalizedBlobID = blobID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard
            normalizedBlobID.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ) != nil
        else {
            throw KeepTalkingBlobStoreError.invalidBlobID(blobID)
        }
        return normalizedBlobID
    }
}
