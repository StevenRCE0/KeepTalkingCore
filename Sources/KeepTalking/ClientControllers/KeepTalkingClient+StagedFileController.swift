import Foundation
import MCP

extension KeepTalkingClient {

    /// Reserved built-in action id for the file-staging preflight. A caller
    /// dispatches a call to this id (carrying the file as an OTB inputTransfer)
    /// to stage a file on the target ahead of a real tool call; the result
    /// carries the staged-file handle.
    static let stageFileActionID = UUID(uuidString: "00000000-0000-0000-0000-0000005746E0")!

    // MARK: - Caller side (preflight)

    /// Preflights `fileURL` onto `target`: streams it as a one-time encrypted blob,
    /// asks the target to stage it, and returns the handle to reference in a later
    /// tool call's input. Point-to-point and ephemeral (caller-scoped, expiring).
    /// `desiredHandle` preserves the caller's ORIGINAL handle across the hop (the
    /// cross-node re-feed relay) so the agent's handle still equals the executor's
    /// `$KT_<KIND>_<HEX>` env key; absent ⇒ the target mints a fresh handle (a plain
    /// kt_send_file). The remote path is cross-platform; only a LOCAL-target stage
    /// (no peer hop) is macOS-only.
    func sendFile(
        fileURL: URL,
        filename: String,
        mimeType: String,
        to target: UUID,
        contextID: UUID,
        desiredHandle: UUID? = nil
    ) async throws -> UUID {
        // Local target: an OTB streamed to self never loops back to our own
        // assembler (it would just time out), so stage the file directly.
        if target == config.node {
            #if os(macOS)
            guard
                let staged = await stagedFileStore.stageLocalFile(
                    at: fileURL, filename: filename, callerNodeID: config.node,
                    consumeOnUse: true)
            else { throw KeepTalkingOneTimeBlobError.sourceUnreadable(fileURL.path) }
            return staged.handle
            #else
            throw KeepTalkingOneTimeBlobError.sourceUnreadable(fileURL.path)
            #endif
        }

        let ref = try await sendOneTimeBlob(
            fileURL: fileURL, filename: filename, mimeType: mimeType, to: target)
        var arguments: [String: Value] = [:]
        if let desiredHandle {
            arguments["desired_handle"] = .string(desiredHandle.uuidString.lowercased())
        }
        let call = KeepTalkingActionCall(
            action: Self.stageFileActionID, arguments: arguments, inputTransfers: [ref])
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
    }

    // MARK: - Cross-node re-feed relay (caller side, cross-platform)

    /// Ships every `inputHandle` on `call` that resolves to a file in THIS node's
    /// staged store to a REMOTE `target`, re-staging it there UNDER THE SAME HANDLE
    /// (via `sendFile`'s `desiredHandle`) so the executor resolves `$KT_<KIND>_<HEX>`
    /// (the agent's handle == the env key). This is what makes A→B chaining of a
    /// produced `.otb` work cross-node: the agent only ever holds a handle, and the
    /// execution layer moves the bytes. Handles that AREN'T local staged files
    /// (already target-side from a prior kt_send_file, or context-attachment handles)
    /// are left untouched. Best-effort: a relay failure is logged and the executor's
    /// MISS log surfaces the gap. `call.inputHandles` is unchanged (preserved).
    func relayLocalStagedInputs(
        _ call: KeepTalkingActionCall, to target: UUID, contextID: UUID
    ) async {
        guard let handles = call.inputHandles, !handles.isEmpty else { return }
        for handle in handles {
            guard
                let staged = await stagedFileStore.file(
                    handle: handle, callerNodeID: config.node)
            else { continue }  // not local → already remote, or a context attachment
            let mime = MIMEType.inferredMIMEType(
                forFileAt: staged.url,
                filename: staged.filename)
            do {
                _ = try await sendFile(
                    fileURL: staged.url, filename: staged.filename, mimeType: mime,
                    to: target, contextID: contextID, desiredHandle: handle)
                onLog?(
                    "[io/staged-input] relayed handle=\(handle.uuidString.prefix(8)) "
                        + "→ target=\(target.uuidString.prefix(8)) (\(staged.byteCount) bytes)")
            } catch {
                onLog?(
                    "[io/staged-input] FAILED relay handle=\(handle.uuidString.prefix(8)) "
                        + "→ target=\(target.uuidString.prefix(8)): \(error.localizedDescription)")
            }
        }
    }

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

        // A cross-node RE-FEED relay carries the caller's ORIGINAL staged handle in
        // `desired_handle` so we stage UNDER it — keeping the agent's handle equal to
        // the executor's `$KT_<KIND>_<HEX>` env key. Absent ⇒ mint a fresh handle
        // (a plain kt_send_file preflight). Caller-scoped either way, so a chosen
        // handle can only affect this caller's own namespace.
        let desiredHandle = request.call.arguments["desired_handle"]?.stringValue
            .flatMap { UUID(uuidString: $0) }

        // Reserve a staging slot within the count/byte quotas BEFORE decrypting;
        // an over-quota stage is refused outright rather than evicting another
        // caller's staged file.
        guard
            let (mintedHandle, dir) = await stagedFileStore.makeStagingDirectory(
                expectedBytes: ref.byteCount, callerNodeID: request.callerNodeID)
        else { return failure("stage-file rejected: staging quota exceeded.") }
        let handle = desiredHandle ?? mintedHandle
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
