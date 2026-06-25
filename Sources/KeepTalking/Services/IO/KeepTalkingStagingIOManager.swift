import Foundation

final class KeepTalkingStagingIOManager {
    unowned let client: KeepTalkingClient
    let store: KeepTalkingStagingIOStore

    init(client: KeepTalkingClient, store: KeepTalkingStagingIOStore) {
        self.client = client
        self.store = store
    }

    struct PreparedInputs {
        let directory: URL?
        let attachments: [KeepTalkingIOManager.StagedInputResource]
        let otbInputs: [(handle: UUID, url: URL)]
        fileprivate let ownedDirectories: [URL]
    }

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

    func cleanup(_ inputs: PreparedInputs) {
        for directory in inputs.ownedDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func file(
        handle: UUID,
        callerNodeID: UUID
    ) async -> (url: URL, filename: String, byteCount: Int)? {
        await store.file(handle: handle, callerNodeID: callerNodeID)
    }

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
            consumeOnUse: consumeOnUse)
    }

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
            consumeOnUse: consumeOnUse)
    }

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

    private func scratchDirectory(prefix: String, id: UUID) -> URL {
        let envTemp = ProcessInfo.processInfo.environment["TMPDIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tempRoot = envTemp?.isEmpty == false ? envTemp! : NSTemporaryDirectory()
        return URL(fileURLWithPath: tempRoot, isDirectory: true)
            .appendingPathComponent("\(prefix)-\(id.uuidString.lowercased())", isDirectory: true)
    }

    private func safeFileName(_ filename: String, fallback: String) -> String {
        let name = (filename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            return fallback
        }
        return name.replacingOccurrences(of: "\\", with: "_")
    }

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
