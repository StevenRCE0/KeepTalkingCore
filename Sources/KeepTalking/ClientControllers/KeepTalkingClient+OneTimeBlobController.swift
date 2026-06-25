import Foundation
import MCP

extension KeepTalkingClient {

    // MARK: - Caller-side filesystem transfer plumbing

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

    /// Sweeps leftover OTB temp directories from prior runs (decrypted get-file
    /// outputs, put-file input staging, and inbound ciphertext buffers) so a
    /// crash can't leave decrypted plaintext at rest. Safe at startup — no
    /// transfers are in flight yet. (Within a run, the get-file output dir
    /// outlives its dispatch call for transcript injection; this is the backstop
    /// until run-scoped cleanup lands.)
    static func pruneStaleOneTimeBlobTempDirs() {
        let fileManager = FileManager.default
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let prefixes = [
            "kt-otb-recv-", "kt-otb-fsin-", "kt-otb-skillin-", "kt-otb-inbound",
            "kt-attach-", "kt-staged-files",
        ]
        guard let entries = try? fileManager.contentsOfDirectory(atPath: tempBase.path)
        else { return }
        for name in entries where prefixes.contains(where: { name.hasPrefix($0) }) {
            try? fileManager.removeItem(at: tempBase.appendingPathComponent(name))
        }
    }

    /// Streams `fileURL` to `recipientNodeID` as an encrypted one-time blob and
    /// returns the ref (carrying the sealed per-transfer key) to embed in the
    /// action-call request/result. Point-to-point and ephemeral — no blob
    /// record, no context attachment, no broadcast.
    func sendOneTimeBlob(
        fileURL: URL,
        filename: String,
        mimeType: String,
        to recipientNodeID: UUID
    ) async throws -> KeepTalkingOneTimeBlobRef {
        let transferID = UUID()
        let key = KeepTalkingOneTimeBlobCrypto.generateKey()
        let sealedKey = try await encryptAsymmetricPayload(
            KeepTalkingOneTimeBlobCrypto.keyData(key),
            recipientNodeID: recipientNodeID,
            purpose: "otb-key"
        )

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw KeepTalkingOneTimeBlobError.sourceUnreadable(fileURL.path)
        }
        defer { try? handle.close() }

        var chunkIndex = 0
        var byteCount = 0
        while true {
            let plaintext = handle.readData(
                ofLength: KeepTalkingOneTimeBlobCrypto.plaintextChunkSize)
            if plaintext.isEmpty { break }
            byteCount += plaintext.count
            let sealed = try KeepTalkingOneTimeBlobCrypto.sealChunk(
                plaintext, key: key,
                aad: KeepTalkingOneTimeBlobCrypto.chunkAAD(
                    transferID: transferID, chunkIndex: chunkIndex))
            try sendOneTimeBlobFrame(
                kind: .chunk,
                transferID: transferID,
                recipient: recipientNodeID,
                mimeType: mimeType,
                chunkIndex: chunkIndex,
                chunkCount: nil,
                byteCount: nil,
                payload: sealed
            )
            // Let the SCTP send buffer drain between chunks (mirrors the
            // attachment blob streamer).
            try await Task.sleep(nanoseconds: 10_000_000)
            chunkIndex += 1
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        try sendOneTimeBlobFrame(
            kind: .complete,
            transferID: transferID,
            recipient: recipientNodeID,
            mimeType: mimeType,
            chunkIndex: nil,
            chunkCount: chunkIndex,
            byteCount: byteCount,
            payload: Data()
        )

        return KeepTalkingOneTimeBlobRef(
            transferID: transferID,
            filename: filename,
            mimeType: mimeType,
            byteCount: byteCount,
            sealedKey: sealedKey
        )
    }

    private func sendOneTimeBlobFrame(
        kind: KeepTalkingBlobTransferKind,
        transferID: UUID,
        recipient: UUID,
        mimeType: String,
        chunkIndex: Int?,
        chunkCount: Int?,
        byteCount: Int?,
        payload: Data
    ) throws {
        let header = KeepTalkingBlobTransferHeader(
            kind: kind,
            transferID: transferID,
            senderNodeID: config.node,
            recipientNodeID: recipient,
            blobID: transferID.uuidString.lowercased(),
            mimeType: mimeType,
            pathExtension: nil,
            byteCount: byteCount,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            chunkByteCount: kind == .chunk ? payload.count : nil,
            isEphemeral: true
        )
        let data = try KeepTalkingBlobTransferCodec.encode(
            KeepTalkingBlobTransferFrame(header: header, payload: payload))
        try rtcClient.sendBlobData(data, targetPeerNodeID: recipient)
    }

    /// Routes an inbound ephemeral frame to the assembler. Called from
    /// `handleIncomingBlobFrameData` when `header.isEphemeral == true`.
    func handleIncomingOneTimeBlobFrame(_ frame: KeepTalkingBlobTransferFrame) async {
        switch frame.header.kind {
            case .chunk:
                // Drop malformed frames rather than coercing a nil index to 0
                // (which a hostile/buggy sender could use to clobber chunk 0).
                guard let chunkIndex = frame.header.chunkIndex else { return }
                await oneTimeBlobAssembler.appendChunk(
                    transferID: frame.header.transferID,
                    chunkIndex: chunkIndex,
                    payload: frame.payload
                )
            case .complete:
                guard let chunkCount = frame.header.chunkCount else { return }
                await oneTimeBlobAssembler.markComplete(
                    transferID: frame.header.transferID,
                    chunkCount: chunkCount
                )
        }
    }

    /// Awaits completion of an inbound OTB (hard timeout), unseals the
    /// per-transfer key (verifying it came from `senderNodeID`), decrypts the
    /// chunks, and writes the plaintext into `directory` as `ref.filename`.
    /// Discards the ciphertext buffer afterward. Returns the file URL.
    func materializeOneTimeBlob(
        _ ref: KeepTalkingOneTimeBlobRef,
        from senderNodeID: UUID,
        into directory: URL,
        timeout: TimeInterval = 60
    ) async throws -> URL {
        let assembler = oneTimeBlobAssembler
        let completed: Bool = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await assembler.awaitCompletion(transferID: ref.transferID)
                return true
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        guard completed else {
            await assembler.discard(
                transferID: ref.transferID,
                error: KeepTalkingOneTimeBlobError.transferTimedOut(ref.transferID))
            throw KeepTalkingOneTimeBlobError.transferTimedOut(ref.transferID)
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

        // The filename is wire-controlled, so reduce it to a single safe path
        // component: `lastPathComponent` strips every directory separator, and we
        // reject "", ".", ".." and any residual "/". A single sanitized component
        // appended to `directory` is PROVABLY a direct child — so containment is
        // guaranteed by construction. We deliberately do NOT compare canonicalised
        // absolute paths: on iOS the temp dir is reached via the /var→/private/var
        // symlink, and Foundation resolves the (non-existent) leaf path to
        // /private/var while leaving the existing directory at /var, which makes
        // any hasPrefix/standardized comparison report a false escape.
        let safeName = (ref.filename as NSString).lastPathComponent
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
}
