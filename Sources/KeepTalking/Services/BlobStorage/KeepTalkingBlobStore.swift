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

    /// Delete a blob's on-disk bytes — both the promoted (ready) file and any
    /// leftover partial. `relativePath` comes from the blob record; pass it when
    /// known so we don't have to reconstruct the extension. Missing files are a
    /// no-op, so this is safe to call on records that never reached `.ready`.
    public func remove(blobID: String, relativePath: String?) throws {
        if let relativePath {
            let fileURL = fileURL(forRelativePath: relativePath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
        try? removePartial(blobID: blobID)
    }

    /// Delete on-disk blob files that no record claims. A *ready* file (under
    /// `prefix/hash.ext`) is kept iff its path is in `keepRelativePaths`; a
    /// *partial* file (under `partial/prefix/hash.part`) is kept iff the blob ID
    /// in its name is in `keepBlobIDs`. Everything else is orphaned bytes — a
    /// record was deleted without its file, a write landed without being
    /// recorded, or a transfer left a partial behind that no record ever indexed
    /// — and gets removed. Partial files we can't parse a valid blob ID from are
    /// left alone (we only delete what we can positively identify as unindexed).
    /// Returns how many files were removed and how many bytes that reclaimed.
    @discardableResult
    public func pruneOrphanFiles(
        keepRelativePaths: Set<String>,
        keepBlobIDs: Set<String>
    ) throws -> (removedCount: Int, freedBytes: Int) {
        var removedCount = 0
        var freedBytes = 0

        try enumerateFiles { fileURL, relativePath, fileSize in
            if relativePath.hasPrefix("partial/") {
                // Indexed iff a record tracks the blob ID encoded in the filename.
                guard let blobID = blobID(fromRelativePath: relativePath),
                    !keepBlobIDs.contains(blobID)
                else { return }
            } else if keepRelativePaths.contains(relativePath) {
                return
            }

            try FileManager.default.removeItem(at: fileURL)
            removedCount += 1
            freedBytes += fileSize
        }

        return (removedCount, freedBytes)
    }

    /// Every blob file on disk, keyed the way records key them.
    ///
    /// This is the file tree standing in for an index: what reclamation falls
    /// back to when a database cannot be read and that identity's reference set
    /// has to be assumed maximal. Ready and partial files are both reported —
    /// the caller can tell them apart by the `partial/` prefix on the path.
    ///
    /// Files whose name is not a well-formed blob hash are skipped. They are not
    /// blobs, so no identity may claim them and nothing may delete them on that
    /// basis — the same rule `pruneOrphanFiles` applies to unparseable partials.
    public func scanBlobFiles() -> [(blobID: String, relativePath: String)] {
        var found = [(blobID: String, relativePath: String)]()
        enumerateFiles { _, relativePath, _ in
            guard let blobID = blobID(fromRelativePath: relativePath) else { return }
            found.append((blobID: blobID, relativePath: relativePath))
        }
        return found
    }

    /// Walks every regular file under `baseURL`, handing `body` the URL, the
    /// path relative to `baseURL`, and the file's size (0 when unavailable).
    ///
    /// Shared by the two full-tree walks so they agree on what counts as a blob
    /// file. Safe for `body` to delete the file it was handed —
    /// `FileManager.DirectoryEnumerator` tolerates removal of already-visited
    /// entries.
    private func enumerateFiles(
        _ body: (_ fileURL: URL, _ relativePath: String, _ fileSize: Int) throws -> Void
    ) rethrows {
        guard
            let enumerator = FileManager.default.enumerator(
                at: baseURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard resourceValues?.isRegularFile == true,
                let relativePath = relativePath(of: fileURL)
            else { continue }

            try body(fileURL, relativePath, resourceValues?.fileSize ?? 0)
        }
    }

    /// Path of `fileURL` relative to `baseURL`, in the same `prefix/hash.ext`
    /// shape stored on blob records. `nil` if the URL isn't under `baseURL`.
    private func relativePath(of fileURL: URL) -> String? {
        let basePath = baseURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(basePath) else { return nil }
        var relative = String(filePath.dropFirst(basePath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative.isEmpty ? nil : relative
    }

    /// The blob ID encoded in a file's name — `prefix/hash.ext` for a ready file,
    /// `partial/prefix/hash.part` for a partial — or `nil` if it isn't a
    /// well-formed blob hash. Mirrors `relativePath(for:pathExtension:)` and
    /// `partialRelativePath(for:)`, which both put the hash in the file name.
    private func blobID(fromRelativePath relativePath: String) -> String? {
        let fileName = (relativePath as NSString).lastPathComponent
        let candidate = (fileName as NSString).deletingPathExtension
        return try? normalizedBlobID(candidate)
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
