import Foundation
import MCP

extension KeepTalkingClient {

    // MARK: - Caller-side filesystem transfer plumbing

    func withStagingResources(
        for request: KeepTalkingActionCallRequest,
        operation: (KeepTalkingActionCallRequest) async throws -> KeepTalkingActionCallResult
    ) async throws -> KeepTalkingActionCallResult {
        await relayLocalStagedInputs(
            request.call,
            to: request.targetNodeID,
            contextID: request.contextID
        )
        var stagedRequest = request
        stagedRequest.call = try await preparingOutgoingFilesystemTransfers(
            request.call,
            recipient: request.targetNodeID
        )
        let result = try await operation(stagedRequest)

        return try await materializingStagedResources(
            result,
            from: request.targetNodeID
        )
    }

    /// If `call` is a filesystem `put-file` carrying a local `source`, streams
    /// that file to `recipient` as a one-time encrypted blob and returns a copy
    /// of the call with the ref attached as an input transfer. Any other call
    /// passes through unchanged — gated purely by the op/arg shape, so non-fs
    /// and local calls are never touched.
    func preparingOutgoingFilesystemTransfers(
        _ call: KeepTalkingActionCall,
        recipient: UUID
    ) async throws -> KeepTalkingActionCall {
        let (op, args) = filesystemOpAndArguments(call)
        guard op == KeepTalkingFilesystemOperation.putFile.rawValue,
            case .string(let source)? = args["source"],
            !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return call }

        let sourceURL = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        let mimeType = MIMEType.inferredMIMEType(
            forFileAt: sourceURL,
            filename: sourceURL.lastPathComponent)
        let ref = try await sendOneTimeBlob(
            fileURL: sourceURL,
            filename: sourceURL.lastPathComponent,
            mimeType: mimeType,
            to: recipient
        )
        var prepared = call
        prepared.inputTransfers = (prepared.inputTransfers ?? []) + [ref]
        return prepared
    }

    /// Materializes any `outputTransfers` a remote filesystem result carried
    /// (e.g. get-file) into `directory`, appending a note per file so the agent
    /// knows where each landed. Returns the augmented result.
    func materializingIncomingFilesystemTransfers(
        _ result: KeepTalkingActionCallResult,
        from senderNodeID: UUID,
        into directory: URL
    ) async throws -> KeepTalkingActionCallResult {
        guard let transfers = result.outputTransfers, !transfers.isEmpty else {
            return result
        }
        var augmented = result
        for ref in transfers {
            let url = try await materializeOneTimeBlob(
                ref, from: senderNodeID, into: directory)
            augmented.content.append(
                .text(
                    text: "Received \(ref.filename) (\(ref.byteCount) bytes) at \(url.path).",
                    annotations: nil, _meta: nil))
        }
        augmented.outputTransfers = nil
        return augmented
    }

    private func materializingStagedResources(
        _ result: KeepTalkingActionCallResult,
        from senderNodeID: UUID
    ) async throws -> KeepTalkingActionCallResult {
        guard let transfers = result.outputTransfers, !transfers.isEmpty else {
            return result
        }

        let producedOTBIDs = Set(
            (result.producedResources ?? []).compactMap {
                $0.kind == "otb" ? $0.resourceID : nil
            }
        )
        let producedTransfers = transfers.filter {
            producedOTBIDs.contains($0.transferID)
        }
        if !producedTransfers.isEmpty {
            await KeepTalkingIOManager(client: self)
                .materializeProducedOTBOutputs(producedTransfers, from: senderNodeID)
        }

        let filesystemTransfers = transfers.filter {
            !producedOTBIDs.contains($0.transferID)
        }
        guard !filesystemTransfers.isEmpty else {
            var staged = result
            staged.outputTransfers = nil
            return staged
        }

        var filesystemResult = result
        filesystemResult.outputTransfers = filesystemTransfers
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "kt-otb-recv-\(result.requestID.uuidString.lowercased())",
                isDirectory: true
            )
        return try await materializingIncomingFilesystemTransfers(
            filesystemResult,
            from: senderNodeID,
            into: directory
        )
    }

    /// Extracts the filesystem operation name + its argument dict, mirroring
    /// FilesystemActionManager's proxy (`tool` + nested `arguments`) and direct
    /// (`operation`) call shapes.
    func filesystemOpAndArguments(
        _ call: KeepTalkingActionCall
    ) -> (op: String?, args: [String: Value]) {
        if case .string(let tool)? = call.arguments["tool"] {
            if let nested = call.arguments["arguments"]?.objectValue {
                return (tool, nested)
            }
            var passthrough = call.arguments
            passthrough.removeValue(forKey: "tool")
            return (tool, passthrough)
        }
        if case .string(let op)? = call.arguments["operation"] {
            return (op, call.arguments)
        }
        return (nil, call.arguments)
    }
}

extension KeepTalkingClient {

    /// Sweeps leftover OTB temp directories from PRIOR RUNS (decrypted get-file
    /// outputs, put-file input staging, and inbound ciphertext buffers) so a
    /// crash can't leave decrypted plaintext at rest. (Within a run, the get-file
    /// output dir outlives its dispatch call for transcript injection; this is
    /// the backstop until run-scoped cleanup lands.)
    ///
    /// Runs exactly ONCE per process, at the first client's construction. The
    /// sweep deletes whole shared roots — `kt-staged-files` holds every client's
    /// staged bytes — so running it again when a later client is built wipes
    /// files the earlier clients are still using: their store entries survive
    /// while the bytes underneath them vanish. Only the first construction can
    /// know that everything on disk is genuinely stale, because no client (and
    /// so no staged file) exists before it.
    static func pruneStaleOneTimeBlobTempDirsOnce() {
        _ = pruneOnce
    }

    /// The once-per-process latch. A `static let` is initialized lazily and
    /// exactly once, even under concurrent access.
    private static let pruneOnce: Void = {
        pruneStaleOneTimeBlobTempDirs()
    }()

    static func pruneStaleOneTimeBlobTempDirs() {
        let fileManager = FileManager.default
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let prefixes = [
            "kt-otb-recv-", "kt-otb-fsin-", "kt-otb-skillin-", "kt-otb-inbound", "kt-otb-outbox",
            "kt-attach-", "kt-staged-files",
        ]
        guard let entries = try? fileManager.contentsOfDirectory(atPath: tempBase.path)
        else { return }
        for name in entries where prefixes.contains(where: { name.hasPrefix($0) }) {
            try? fileManager.removeItem(at: tempBase.appendingPathComponent(name))
        }
    }

    /// Holds `fileURL` for `recipientNodeID` as an encrypted one-time blob and
    /// returns the ref (carrying the sealed per-transfer key) to embed in the
    /// action-call request/result. The recipient pulls the bytes from this
    /// node when the ref arrives. Point-to-point and ephemeral — no blob
    /// record, no context attachment, no broadcast.
    func sendOneTimeBlob(
        fileURL: URL,
        filename: String,
        mimeType: String,
        to recipientNodeID: UUID
    ) async throws -> KeepTalkingOneTimeBlobRef {
        let key = KeepTalkingOneTimeBlobCrypto.generateKey()
        let sealedKey = try await encryptAsymmetricPayload(
            KeepTalkingOneTimeBlobCrypto.keyData(key),
            recipientNodeID: recipientNodeID,
            purpose: "otb-key"
        )
        let (transferID, byteCount) = try await oneTimeBlobOutbox.hold(
            fileURL: fileURL,
            key: key,
            recipient: recipientNodeID,
            mimeType: mimeType
        )
        return KeepTalkingOneTimeBlobRef(
            transferID: transferID,
            filename: filename,
            mimeType: mimeType,
            byteCount: byteCount,
            sealedKey: sealedKey
        )
    }

    /// Holder side of a pull: streams the held file to its recipient, each
    /// chunk sealed with the transfer's key, from chunk `fromChunk` on.
    func streamOneTimeBlob(
        _ entry: KeepTalkingOneTimeBlobOutbox.Entry,
        transferID: UUID,
        fromChunk: Int
    ) async throws {
        let chunkSize = KeepTalkingOneTimeBlobCrypto.plaintextChunkSize
        let handle = try FileHandle(forReadingFrom: entry.fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(fromChunk, 0) * chunkSize))
        let header = KeepTalkingBlobStreamHeader(
            item: .oneTimeBlob(transferID: transferID),
            offset: fromChunk,
            byteCount: entry.byteCount,
            mimeType: entry.mimeType,
            pathExtension: nil
        )
        let writer = try await connection.openBlobStream(to: entry.recipient, header: try JSONEncoder().encode(header))
        do {
            var chunkIndex = fromChunk
            while let plaintext = try handle.read(upToCount: chunkSize), !plaintext.isEmpty {
                try await writer.write(
                    try KeepTalkingOneTimeBlobCrypto.sealChunk(
                        plaintext,
                        key: entry.key,
                        aad: KeepTalkingOneTimeBlobCrypto.chunkAAD(transferID: transferID, chunkIndex: chunkIndex)
                    )
                )
                chunkIndex += 1
            }
            try await writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
    }

    /// Starts pulling the refs' bytes from `holder` — the node whose request
    /// or result carried them — so they're here, or on their way, before
    /// anything materializes them. A tight agent run then never waits a
    /// round trip it didn't have to.
    func prefetchOneTimeBlobs(_ refs: [KeepTalkingOneTimeBlobRef], from holder: UUID) {
        guard !refs.isEmpty, holder != config.node else { return }
        Task {
            for ref in refs { await self.pullOneTimeBlob(ref.transferID, from: holder) }
        }
    }

    /// Prefetches a request's inputs when it's addressed to us; its caller
    /// holds them.
    func prefetchOneTimeBlobs(for request: KeepTalkingActionCallRequest) {
        guard request.targetNodeID == config.node else { return }
        prefetchOneTimeBlobs(request.call.inputTransfers ?? [], from: request.callerNodeID)
    }

    /// Prefetches a result's outputs when it answers us; the executor holds
    /// them.
    func prefetchOneTimeBlobs(for result: KeepTalkingActionCallResult) {
        guard result.callerNodeID == config.node else { return }
        prefetchOneTimeBlobs(result.outputTransfers ?? [], from: result.targetNodeID)
    }

    /// Asks `holder` to stream the transfer, unless a pull of it is already
    /// in flight or done.
    func pullOneTimeBlob(_ transferID: UUID, from holder: UUID) async {
        guard await oneTimeBlobAssembler.beginPull(transferID, from: holder) else { return }
        connection.expectBlobStream(from: holder)
        do {
            try sendEnvelope(
                KeepTalkingBlobTransferEnvelope(
                    context: config.contextID,
                    sender: config.node,
                    recipient: holder,
                    step: .pull(.oneTimeBlob(transferID: transferID), offset: 0)
                )
            )
        } catch {
            await oneTimeBlobAssembler.pullFailed(
                transferID,
                error: KeepTalkingOneTimeBlobError.transferFailed(transferID, error.localizedDescription)
            )
        }
    }

    /// Receiver side of a pull: hands the sealed chunks to the assembler.
    func receiveOneTimeBlob(
        _ transferID: UUID,
        header: KeepTalkingBlobStreamHeader,
        reader: any KeepTalkingBlobStreamReader,
        from holder: UUID
    ) async {
        let assembler = oneTimeBlobAssembler
        guard await assembler.isPulling(transferID, from: holder) else {
            reader.cancel()
            return
        }
        do {
            var chunkIndex = header.offset
            while let chunk = try await reader.next() {
                await assembler.appendChunk(transferID: transferID, chunkIndex: chunkIndex, payload: chunk)
                chunkIndex += 1
            }
            await assembler.markComplete(transferID: transferID, chunkCount: chunkIndex)
        } catch {
            reader.cancel()
            await assembler.pullFailed(
                transferID,
                error: KeepTalkingOneTimeBlobError.transferFailed(transferID, error.localizedDescription)
            )
        }
    }

    /// Pulls an inbound OTB from `senderNodeID` (its holder) unless that's
    /// under way, awaits it (hard timeout), unseals the per-transfer key
    /// (verifying it came from `senderNodeID`), decrypts the chunks, and
    /// writes the plaintext into `directory` as `ref.filename`. A pull that
    /// breaks is retried; a holder that no longer has it ends it. Discards
    /// the ciphertext buffer afterward. Returns the file URL.
    func materializeOneTimeBlob(
        _ ref: KeepTalkingOneTimeBlobRef,
        from senderNodeID: UUID,
        into directory: URL,
        timeout: TimeInterval = 60
    ) async throws -> URL {
        let assembler = oneTimeBlobAssembler
        let deadline = Date().addingTimeInterval(timeout)
        var retries = 2
        while true {
            await pullOneTimeBlob(ref.transferID, from: senderNodeID)
            do {
                try await Self.awaitOneTimeBlob(ref.transferID, on: assembler, until: deadline)
                break
            } catch KeepTalkingOneTimeBlobError.transferFailed where retries > 0 {
                retries -= 1
            } catch {
                await assembler.discard(transferID: ref.transferID, error: error)
                throw error
            }
        }
        // Reclaim the ciphertext buffer + assembler entry on every exit below
        // (success or throw), not just the happy path.
        defer { Task { [assembler] in await assembler.discard(transferID: ref.transferID) } }

        let keyData = try await decryptAsymmetricPayload(
            ref.sealedKey,
            expectedSenderNodeID: senderNodeID,
            purpose: "otb-key"
        )
        let key = KeepTalkingOneTimeBlobCrypto.key(from: keyData)
        let chunks = try await assembler.orderedCiphertextChunks(transferID: ref.transferID)

        let safeName = (ref.filename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty, safeName != ".", safeName != "..",
            !safeName.contains("/")
        else {
            throw KeepTalkingOneTimeBlobError.materializationFailed(
                "OTB rejected unsafe filename '\(ref.filename)'.")
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(safeName, isDirectory: false)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: destination)
        defer { try? writeHandle.close() }
        var written = 0
        for chunk in chunks {
            let plaintext: Data
            do {
                plaintext = try KeepTalkingOneTimeBlobCrypto.openChunk(
                    chunk.data, key: key,
                    aad: KeepTalkingOneTimeBlobCrypto.chunkAAD(
                        transferID: ref.transferID, chunkIndex: chunk.index))
            } catch {
                // AEAD failure for this chunk = wrong key or corrupt ciphertext.
                throw KeepTalkingOneTimeBlobError.materializationFailed(
                    "OTB chunk \(chunk.index) failed to decrypt (wrong key or corrupt data).")
            }
            try writeHandle.write(contentsOf: plaintext)
            written += plaintext.count
        }
        // Reject a transfer whose decrypted size doesn't match the declared
        // byte count — catches missing/extra chunks that slipped the assembler.
        guard written == ref.byteCount else {
            throw KeepTalkingOneTimeBlobError.materializationFailed(
                "OTB transfer incomplete: decrypted \(written) of \(ref.byteCount) bytes.")
        }
        return destination
    }

    /// Waits for the assembler to finish `transferID`, or throws
    /// `transferTimedOut` at `deadline`.
    private static func awaitOneTimeBlob(
        _ transferID: UUID,
        on assembler: KeepTalkingOneTimeBlobAssembler,
        until deadline: Date
    ) async throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw KeepTalkingOneTimeBlobError.transferTimedOut(transferID) }
        let completed: Bool = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await assembler.awaitCompletion(transferID: transferID)
                return true
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        guard completed else { throw KeepTalkingOneTimeBlobError.transferTimedOut(transferID) }
    }
}
