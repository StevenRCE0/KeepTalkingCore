import Foundation

/// Coordinates staging of input/output files for action calls on this node.
///
/// Wraps `KeepTalkingStagingIOStore` (the quota/TTL-enforcing actor) with the
/// context-aware logic the executor needs: materializing a context's blob
/// attachments into a scratch dir, resolving OTB input handles into per-call
/// directories, and tearing those scratch dirs down once the call finishes.
/// Scratch dirs created here are tracked in `PreparedInputs.ownedDirectories`
/// and removed by `cleanup` — the store's own staged files are reclaimed by TTL.
final class KeepTalkingStagingIOManager {
    unowned let client: KeepTalkingClient
    let store: KeepTalkingStagingIOStore

    init(client: KeepTalkingClient, store: KeepTalkingStagingIOStore) {
        self.client = client
        self.store = store
    }

    /// Scratch state for one action call: the merged attachments/OTB directory
    /// (if any), the attachment resources to expose to the model, the resolved
    /// OTB input handles, and the temp dirs `cleanup` is responsible for.
    struct PreparedInputs {
        /// Single scratch dir holding both context attachments and OTB inputs,
        /// or nil if the call has no file inputs at all.
        let directory: URL?
        let attachments: [KeepTalkingIOManager.StagedInputResource]
        let otbInputs: [(handle: UUID, url: URL)]
        /// Temp dirs created by `prepareInputs` that `cleanup` must remove.
        fileprivate let ownedDirectories: [URL]
    }

    /// Materializes every file input a call needs into a single scratch dir:
    /// context blob attachments first, then OTB input handles (reusing the same
    /// dir if attachments already created one, else a fresh `kt-otb-skillin`
    /// dir). Returns the merged result for `prepareCallBinding`.
    func prepareInputs(
        action: KeepTalkingAction,
        request: KeepTalkingActionCallRequest
    ) async throws -> PreparedInputs {
        var ownedDirectories: [URL] = []
        let contextAttachments = await stageContextAttachments(in: request.contextID)
        var directory = contextAttachments?.directory
        let attachments = contextAttachments?.attachments ?? []
        if let directory { ownedDirectories.append(directory) }

        var otbInputs: [(handle: UUID, url: URL)] = []
        if action.acceptsFileInput, request.call.inputHandles?.isEmpty == false {
            let inputDirectory =
                directory
                ?? scratchDirectory(
                    prefix: "kt-otb-skillin",
                    id: request.id)
            if directory == nil {
                directory = inputDirectory
                ownedDirectories.append(inputDirectory)
            }
            otbInputs = try await resolveStagedInputs(
                request.call,
                callerNodeID: request.callerNodeID,
                into: inputDirectory)
        }

        return PreparedInputs(
            directory: directory,
            attachments: attachments,
            otbInputs: otbInputs,
            ownedDirectories: ownedDirectories)
    }

    /// Removes the temp dirs created by `prepareInputs`. Store-owned staged
    /// files are NOT touched here — they expire via the store's TTL/quota.
    func cleanup(_ inputs: PreparedInputs) {
        for directory in inputs.ownedDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Resolves a caller-owned staged handle to its file URL + metadata.
    /// Returns nil for foreign/unknown/vanished handles (see `store.file`).
    func file(
        handle: UUID,
        callerNodeID: UUID
    ) async -> (url: URL, filename: String, byteCount: Int)? {
        await store.file(handle: handle, callerNodeID: callerNodeID)
    }

    /// Stages an already-local file (e.g. a primitive's private `.otb` output)
    /// for re-feeding into a later action call. Defaults to re-feedable
    /// (`consumeOnUse: false`) so A→B chaining keeps the handle alive.
    func stageLocalFile(
        at sourceURL: URL,
        filename: String,
        callerNodeID: UUID,
        consumeOnUse: Bool = false
    ) async -> (handle: UUID, byteCount: Int)? {
        await store.stageLocalFile(
            at: sourceURL,
            filename: filename,
            callerNodeID: callerNodeID,
            consumeOnUse: consumeOnUse
        )
    }

    /// Registers an already-materialized file under `handle` (used when a
    /// caller pre-allocated the handle, e.g. peer preflight). Defaults to
    /// consume-on-use so ephemeral input relays are destroyed after one call.
    func register(
        handle: UUID,
        url: URL,
        callerNodeID: UUID,
        filename: String,
        byteCount: Int,
        consumeOnUse: Bool = true
    ) async {
        await store.register(
            handle: handle,
            url: url,
            callerNodeID: callerNodeID,
            filename: filename,
            byteCount: byteCount,
            consumeOnUse: consumeOnUse
        )
    }

    /// Materializes a context's blob attachments into a fresh `kt-attach`
    /// scratch dir by hard-linking (falling back to copy) from the blob store.
    /// Returns nil if the context has no attachments, none are ready, or the
    /// dir can't be created — in which case no scratch dir is left behind.
    private func stageContextAttachments(
        in contextID: UUID
    ) async -> (directory: URL, attachments: [KeepTalkingIOManager.StagedInputResource])? {
        guard let contextAttachments = try? await client.contextAttachments(in: contextID),
            !contextAttachments.isEmpty,
            let records = try? await client.blobRecordsByBlobID(
                contextAttachments.map(\.blobID))
        else { return nil }

        let scratch = scratchDirectory(prefix: "kt-attach", id: UUID())
        let fileManager = FileManager.default
        guard
            (try? fileManager.createDirectory(
                at: scratch, withIntermediateDirectories: true)) != nil
        else { return nil }
        let directory = scratch.resolvingSymlinksInPath()

        var attachments: [KeepTalkingIOManager.StagedInputResource] = []
        var usedNames = Set<String>()
        for (index, attachment) in contextAttachments.enumerated() {
            guard let record = records[attachment.blobID],
                record.availability == .ready,
                let relativePath = record.relativePath
            else { continue }

            let source = client.blobStore.fileURL(forRelativePath: relativePath)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = uniqueDestination(
                filename: attachment.filename,
                directory: directory,
                fallback: "attachment_\(index)",
                isTaken: { usedNames.contains($0) })
            usedNames.insert(destination.name)

            if (try? fileManager.linkItem(at: source, to: destination.url)) == nil,
                (try? fileManager.copyItem(at: source, to: destination.url)) == nil
            {
                continue
            }
            attachments.append(
                KeepTalkingIOManager.StagedInputResource(
                    id: attachment.id ?? UUID(),
                    path: destination.url,
                    displayName: destination.name))
        }

        guard !attachments.isEmpty else {
            try? fileManager.removeItem(at: directory)
            return nil
        }
        return (directory, attachments)
    }

    /// Copies each OTB input handle's staged file into `directory`, returning
    /// the (handle, url) pairs that resolved. Misses are logged and skipped —
    /// the call proceeds without them rather than failing the whole action.
    private func resolveStagedInputs(
        _ call: KeepTalkingActionCall,
        callerNodeID: UUID,
        into directory: URL
    ) async throws -> [(handle: UUID, url: URL)] {
        guard let handles = call.inputHandles, !handles.isEmpty else { return [] }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var resolved: [(handle: UUID, url: URL)] = []
        for handle in handles {
            if let url = try? await store.copyStagedFile(
                handle: handle, callerNodeID: callerNodeID, into: directory)
            {
                resolved.append((handle, url))
            } else {
                await logStagedInputMiss(handle: handle, callerNodeID: callerNodeID)
            }
        }
        return resolved
    }

    /// Emits a structured log line explaining why a staged input handle didn't
    /// resolve: distinguishes local self-calls (TTL/discarded) from remote
    /// callers (handle lives on the caller's node, never shipped here).
    private func logStagedInputMiss(handle: UUID, callerNodeID: UUID) async {
        let diagnosis = await store.resolutionDiagnosis(
            handle: handle, callerNodeID: callerNodeID)
        let scope =
            callerNodeID == client.config.node
            ? "scope=local(self-call => TTL/discarded)"
            : "scope=remote(caller-owns-it => not shipped to this node)"
        client.onLog?(
            "[io/staged-input] MISS handle=\(handle.uuidString.prefix(8)) "
                + "caller=\(callerNodeID.uuidString.prefix(8)) \(scope) "
                + "diagnosis=\(diagnosis); input skipped, no $KT_OTB emitted")
    }

    /// Builds a unique temp dir under `$TMPDIR` (or `NSTemporaryDirectory`)
    /// named `<prefix>-<uuid>`. Used for both attachment and OTB scratch dirs.
    private func scratchDirectory(prefix: String, id: UUID) -> URL {
        let envTemp = ProcessInfo.processInfo.environment["TMPDIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tempRoot = envTemp?.isEmpty == false ? envTemp! : NSTemporaryDirectory()
        return URL(fileURLWithPath: tempRoot, isDirectory: true)
            .appendingPathComponent("\(prefix)-\(id.uuidString.lowercased())", isDirectory: true)
    }

    /// Sanitizes a user/peer-supplied filename to a single path component,
    /// falling back to `fallback` when empty, `.`, `..`, or contains slashes.
    private func safeFileName(_ filename: String, fallback: String) -> String {
        let name = (filename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            return fallback
        }
        return name.replacingOccurrences(of: "\\", with: "_")
    }

    /// Picks a non-colliding name for `filename` inside `directory`, prefixing
    /// `1_`, `2_`, … when `isTaken` reports a clash. Used to keep multiple
    /// context attachments with the same display name distinct on disk.
    private func uniqueDestination(
        filename: String,
        directory: URL,
        fallback: String,
        isTaken: (String) -> Bool
    ) -> (name: String, url: URL) {
        let base = safeFileName(filename, fallback: fallback)
        var name = base
        var counter = 1
        while isTaken(name) {
            name = "\(counter)_\(base)"
            counter += 1
        }
        return (name, directory.appendingPathComponent(name, isDirectory: false))
    }
}
