import Foundation
import MCP

extension KeepTalkingClient {

    /// Reserved built-in action id for the file-staging preflight. A caller
    /// dispatches a call to this id (carrying the file as an OTB inputTransfer)
    /// to stage a file on the target ahead of a real tool call; the result
    /// carries the staged-file handle.
    static let stageFileActionID = UUID(uuidString: "00000000-0000-0000-0000-0000005746E0")!

    // MARK: - Caller side (preflight)

    /// Preflights `fileURL` onto `target`: streams it as a one-time encrypted
    /// blob, asks the target to stage it, and returns the handle to reference in
    /// a subsequent tool call's input. Point-to-point and ephemeral — the staged
    /// file is caller-scoped and expires.
    func sendFile(
        fileURL: URL,
        filename: String,
        mimeType: String,
        to target: UUID,
        contextID: UUID
    ) async throws -> UUID {
        #if os(macOS)
        // Local target: there is no peer hop and an OTB streamed to self never
        // loops back to our own assembler (it would just time out), so stage the
        // file directly into the store and return the handle.
        if target == config.node {
            return try await stageLocalFile(fileURL: fileURL, filename: filename)
        }

        let ref = try await sendOneTimeBlob(
            fileURL: fileURL, filename: filename, mimeType: mimeType, to: target)
        let call = KeepTalkingActionCall(
            action: Self.stageFileActionID, inputTransfers: [ref])
        let request = KeepTalkingActionCallRequest(
            contextID: contextID,
            callerNodeID: config.node,
            targetNodeID: target,
            call: call
        )
        try await sendRemoteActionCallRequest(request, deliveryDescription: "stage-file")
        let result = try await waitForActionCallResult(
            requestID: request.id, targetNodeID: target)
        guard !result.isError, let handle = Self.parseStagedHandle(result.content) else {
            throw KeepTalkingOneTimeBlobError.transferTimedOut(ref.transferID)
        }
        return handle
        #else
        throw KeepTalkingOneTimeBlobError.sourceUnreadable(fileURL.path)
        #endif
    }

    #if os(macOS)
    /// Stages a local file (target == self) straight into the store, skipping
    /// OTB entirely. The caller is this node, so the entry is self-scoped.
    private func stageLocalFile(fileURL: URL, filename: String) async throws -> UUID {
        let byteCount =
            ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size]
                as? Int) ?? 0
        guard
            let (handle, dir) = await stagedFileStore.makeStagingDirectory(
                expectedBytes: byteCount, callerNodeID: config.node)
        else { throw KeepTalkingOneTimeBlobError.sourceUnreadable(fileURL.path) }
        let safeName = (filename as NSString).lastPathComponent
        let dest = dir.appendingPathComponent(
            safeName.isEmpty ? "file" : safeName, isDirectory: false)
        do {
            try FileManager.default.copyItem(at: fileURL, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        await stagedFileStore.register(
            handle: handle, url: dest, callerNodeID: config.node,
            filename: filename, byteCount: byteCount)
        return handle
    }
    #endif

    // MARK: - Executor side (preflight handler + resolution)

    #if os(macOS)
    /// Handles an inbound `stage-file` preflight: materializes the streamed
    /// blob into the staged-file store and returns its handle. Authorization is
    /// the staging point — only a *trusted* peer may stage, the file is
    /// caller-scoped, quota-bounded, and TTL-bounded, and the real tool call that
    /// references the handle is authorized separately.
    func handleStageFilePreflight(
        _ request: KeepTalkingActionCallRequest
    ) async -> KeepTalkingActionCallResult {
        func failure(_ message: String) -> KeepTalkingActionCallResult {
            KeepTalkingActionCallResult(
                requestID: request.id, contextID: request.contextID,
                callerNodeID: request.callerNodeID, targetNodeID: request.targetNodeID,
                actionID: Self.stageFileActionID, content: [], isError: true,
                errorMessage: message)
        }
        // Trust gate: the caller must hold a trusted (non-pending) relation
        // toward this node — the same precondition the grant path requires for a
        // locally-hosted action. A merely key-exchanged but ungranted/pending
        // peer is rejected, and we never auto-create the caller as a side effect.
        let trusted =
            (try? await Self.preferredTrustedRelation(
                from: config.node, to: request.callerNodeID,
                allowPending: false, on: localStore.database)) ?? nil
        guard trusted != nil else {
            return failure("Caller is not trusted to stage files.")
        }
        guard let ref = request.call.inputTransfers?.first else {
            return failure("stage-file requires a streamed file.")
        }

        // Reserve a staging slot within the count/byte quotas BEFORE decrypting;
        // an over-quota stage is refused outright rather than evicting another
        // caller's staged file.
        guard
            let (handle, dir) = await stagedFileStore.makeStagingDirectory(
                expectedBytes: ref.byteCount, callerNodeID: request.callerNodeID)
        else { return failure("stage-file rejected: staging quota exceeded.") }
        do {
            let url = try await materializeOneTimeBlob(
                ref, from: request.callerNodeID, into: dir)
            await stagedFileStore.register(
                handle: handle, url: url, callerNodeID: request.callerNodeID,
                filename: ref.filename, byteCount: ref.byteCount)
        } catch {
            // Nothing registered yet, so remove the reserved dir directly.
            try? FileManager.default.removeItem(at: dir)
            return failure("stage-file transfer failed: \(error.localizedDescription)")
        }
        return KeepTalkingActionCallResult(
            requestID: request.id, contextID: request.contextID,
            callerNodeID: request.callerNodeID, targetNodeID: request.targetNodeID,
            actionID: Self.stageFileActionID,
            content: [.text(text: handle.uuidString.lowercased(), annotations: nil, _meta: nil)],
            isError: false)
    }

    /// Resolves a call's `inputHandles` (caller-scoped) to their staged paths and
    /// copies them into `directory` (the action's input staging area). Returns
    /// the copied file URLs. The resolve+copy happens atomically inside the
    /// store's actor (no reap/eviction can delete the file mid-copy) and each
    /// copy lands under a non-colliding name (so two same-named handles, or a
    /// handle whose name matches an already-staged context attachment, don't
    /// clobber each other). Unknown/foreign/raced handles degrade to a skipped
    /// input rather than aborting the whole tool call.
    func resolveStagedInputs(
        _ call: KeepTalkingActionCall,
        callerNodeID: UUID,
        into directory: URL
    ) async throws -> [URL] {
        guard let handles = call.inputHandles, !handles.isEmpty else { return [] }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var resolved: [URL] = []
        for handle in handles {
            if let dest = try? await stagedFileStore.copyStagedFile(
                handle: handle, callerNodeID: callerNodeID, into: directory)
            {
                resolved.append(dest)
            }
        }
        return resolved
    }
    #endif

    private static func parseStagedHandle(_ content: [Tool.Content]) -> UUID? {
        for item in content {
            if case .text(let text, _, _) = item,
                let handle = UUID(
                    uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return handle
            }
        }
        return nil
    }
}
