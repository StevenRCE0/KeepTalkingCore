//
//  KeepTalkingClient+BlobController.swift
//  KeepTalking
//
//  Created by 砚渤 on 24/03/2026.
//

import Crypto
import FluentKit
import Foundation

extension KeepTalkingClient {
    /// Bytes per blob-stream chunk. QUIC flow control paces the stream, so
    /// this only sizes the frames.
    private static let blobStreamChunkSize = 128 * 1024

    func upsertBlobRecord(
        blobID: String,
        relativePath: String?,
        availability: KeepTalkingBlobAvailability,
        mimeType: String,
        byteCount: Int,
        receivedBytes: Int
    ) async throws {
        if let existing = try await KeepTalkingBlobRecord.query(
            on: localStore.database
        )
        .filter(\.$id, .equal, blobID)
        .first() {
            existing.relativePath = relativePath ?? existing.relativePath
            existing.availability = availability
            existing.mimeType = mimeType
            existing.byteCount = byteCount
            existing.receivedBytes = max(existing.receivedBytes, receivedBytes)
            existing.lastAccessedAt = Date()
            try await existing.save(on: localStore.database)
            return
        }

        let record = KeepTalkingBlobRecord(
            blobID: blobID,
            relativePath: relativePath,
            availability: availability,
            mimeType: mimeType,
            byteCount: byteCount,
            receivedBytes: receivedBytes,
            lastAccessedAt: Date()
        )
        try await record.save(on: localStore.database)
    }

    /// The distinct blob IDs referenced by every attachment belonging to
    /// `contextID`. Capture this *before* deleting the context — the cascade on
    /// `kt_context_attachments` wipes the rows, after which the link is gone.
    public static func blobIDsReferenced(
        byContextID contextID: UUID,
        on database: any Database
    ) async throws -> Set<String> {
        let blobIDs = try await KeepTalkingContextAttachment.query(on: database)
            .filter(\.$context.$id, .equal, contextID)
            .all(\.$blobID)
        return Set(blobIDs)
    }

    /// Given blob IDs that *were* referenced by a now-deleted context, delete the
    /// record + on-disk bytes for any that no longer have a single referencing
    /// attachment anywhere in the store. Blobs are shared across contexts by
    /// `blob_id` string alone (no FK), so deleting one context can strand a blob
    /// that another context still uses — hence the per-blob reference check.
    /// Returns the blob IDs that were pruned.
    @discardableResult
    public static func pruneStrayBlobs(
        among candidateBlobIDs: Set<String>,
        on database: any Database,
        blobStore: KeepTalkingBlobStore
    ) async throws -> [String] {
        var pruned: [String] = []
        for blobID in candidateBlobIDs {
            let remainingReferences =
                try await KeepTalkingContextAttachment
                .query(on: database)
                .filter(\.$blobID, .equal, blobID)
                .count()
            guard remainingReferences == 0 else { continue }

            let record = try await KeepTalkingBlobRecord.query(on: database)
                .filter(\.$id, .equal, blobID)
                .first()
            try? blobStore.remove(
                blobID: blobID,
                relativePath: record?.relativePath
            )
            try await record?.delete(on: database)
            pruned.append(blobID)
        }
        return pruned
    }

    /// Sweep the entire store for stray blobs — records with no referencing
    /// attachment anywhere — and delete each one's record + on-disk bytes.
    /// Unscoped counterpart to the per-context prune; use it for an explicit
    /// "reclaim space" action or a periodic housekeeping pass. Returns the
    /// pruned blob IDs.
    @discardableResult
    public static func pruneAllStrayBlobs(
        on database: any Database,
        blobStore: KeepTalkingBlobStore
    ) async throws -> [String] {
        let allBlobIDs = try await KeepTalkingBlobRecord.query(on: database)
            .all(\.$id)
            .compactMap { $0 }
        return try await pruneStrayBlobs(
            among: Set(allBlobIDs),
            on: database,
            blobStore: blobStore
        )
    }

    /// Delete on-disk blob files that no blob record claims — ready bytes orphaned
    /// when a record was removed without its file (or a write landed without being
    /// recorded), plus partial bytes from transfers that no record ever indexed.
    /// Counterpart to `pruneAllStrayBlobs`, which prunes the *records* (and files)
    /// no attachment references; this catches *files* with no backing record at
    /// all. Returns the count removed and bytes freed.
    @discardableResult
    public static func pruneOrphanBlobFiles(
        on database: any Database,
        blobStore: KeepTalkingBlobStore
    ) async throws -> (removedCount: Int, freedBytes: Int) {
        let records = try await KeepTalkingBlobRecord.query(on: database).all()
        return try blobStore.pruneOrphanFiles(
            keepRelativePaths: Set(records.compactMap { $0.relativePath }),
            keepBlobIDs: Set(records.compactMap { $0.id })
        )
    }

    func ensureBlobRecordPlaceholder(
        for attachment: KeepTalkingContextAttachment
    ) async throws {
        let blobID = attachment.blobID
        guard
            try await KeepTalkingBlobRecord.query(on: localStore.database)
                .filter(\.$id, .equal, blobID)
                .first() == nil
        else {
            return
        }

        let record = KeepTalkingBlobRecord(
            blobID: blobID,
            relativePath: nil,
            availability: .missing,
            mimeType: attachment.mimeType,
            byteCount: attachment.byteCount,
            receivedBytes: 0
        )
        try await record.save(on: localStore.database)
    }

    // MARK: - Asking for blobs

    /// Announces the attachments' blobs we're missing to the room.
    func requestAttachmentBlobsIfNeeded(
        for attachments: [KeepTalkingContextAttachment],
        in contextID: UUID
    ) async throws {
        try await announceWantedBlobs(try await missingBlobIDs(for: attachments), in: contextID)
    }

    /// Announces every recent attachment blob we're missing. Runs on each
    /// node-online and heartbeat maintenance pass; announcements of the same
    /// blob are spaced out, so the room hears each once per interval.
    func requestRecentMissingAttachmentBlobs(
        in contextID: UUID,
        since: Date
    ) async throws {
        let attachments = try await recentAttachments(in: contextID, since: since)
        try await announceWantedBlobs(try await missingBlobIDs(for: attachments), in: contextID)
    }

    /// The distinct blob ids among `attachments` that aren't ready here.
    func missingBlobIDs(for attachments: [KeepTalkingContextAttachment]) async throws -> [String] {
        var seen = Set<String>()
        var missing: [String] = []
        for attachment in attachments where seen.insert(attachment.blobID).inserted {
            if try await !isBlobReady(blobID: attachment.blobID) { missing.append(attachment.blobID) }
        }
        return missing
    }

    private func announceWantedBlobs(_ blobIDs: [String], in contextID: UUID) async throws {
        guard !blobIDs.isEmpty else { return }
        let due = await blobPulls.dueForAnnouncement(blobIDs)
        guard !due.isEmpty else { return }
        try sendEnvelope(
            KeepTalkingBlobTransferEnvelope(
                context: contextID,
                sender: config.node,
                recipient: nil,
                step: .wanted(due.map { .attachment(blobID: $0) })
            )
        )
    }

    /// Ask `recipient` for attachment *records* belonging to recent messages
    /// that we have locally but hold no attachment rows for. Repairs orphaned
    /// attachments that incremental message sync can't recover (the parent
    /// message is already past our cursor, so its attachment never re-rides a
    /// delta). Recency-bounded by the same lookback as blob recovery.
    ///
    /// "No local rows" is a heuristic — most messages legitimately have no
    /// attachments — so the responder simply returns empty for those. Payload
    /// is just message UUIDs; cheap relative to closing the data-loss hole.
    func requestRecentMissingAttachmentRecords(
        in contextID: UUID,
        since: Date,
        from recipient: UUID
    ) async throws {
        let messageIDs = try await recentMessageIDsLackingAttachments(
            in: contextID,
            since: since
        )
        guard !messageIDs.isEmpty else { return }

        let request = KeepTalkingContextSyncAttachmentRecordsRequest(
            context: contextID,
            requester: config.node,
            recipient: recipient,
            messageIDs: messageIDs
        )
        try sendEnvelope(
            KeepTalkingContextSyncEnvelope.attachmentRecordsRequest(request)
        )
    }

    /// Message IDs (created since `since`) that have no local attachment rows.
    /// Excludes our own messages — we authored those, so we already hold any
    /// attachments they carry.
    private func recentMessageIDsLackingAttachments(
        in contextID: UUID,
        since: Date
    ) async throws -> [UUID] {
        let messages = try await KeepTalkingContextMessage.query(
            on: localStore.database
        )
        .filter(\.$context.$id, .equal, contextID)
        .with(\.$attachments)
        .all()

        return messages.compactMap { message -> UUID? in
            guard let id = message.id,
                message.timestamp >= since,
                message.attachments.isEmpty,
                case .node(let senderID) = message.sender,
                senderID != config.node
            else { return nil }
            return id
        }
    }

    func hexDigest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Negotiation

    /// Blob negotiation from the room: offers to askers, pulls of offers,
    /// streams for pulls.
    func handleBlobTransferEnvelope(_ envelope: KeepTalkingBlobTransferEnvelope) async {
        guard envelope.sender != config.node else { return }
        if let recipient = envelope.recipient, recipient != config.node { return }
        switch envelope.step {
            case .wanted(let items):
                await offerHeldBlobs(items, to: envelope.sender, in: envelope.context)
            case .offer(let offered):
                await pullOffered(offered, from: envelope.sender, in: envelope.context)
            case .pull(let item, let offset):
                Task { await self.servePull(item, offset: offset, to: envelope.sender, in: envelope.context) }
            case .unavailable(.attachment(let blobID)):
                guard await blobPulls.isPulling(blobID, from: envelope.sender) else { return }
                await blobPulls.finish(blobID)
            case .unavailable(.oneTimeBlob(let transferID)):
                guard await oneTimeBlobAssembler.isPulling(transferID, from: envelope.sender) else { return }
                await oneTimeBlobAssembler.pullFailed(
                    transferID,
                    error: KeepTalkingOneTimeBlobError.unavailable(transferID)
                )
        }
    }

    private func offerHeldBlobs(
        _ items: [KeepTalkingBlobTransferEnvelope.Item],
        to requester: UUID,
        in contextID: UUID
    ) async {
        var offered: [KeepTalkingBlobTransferEnvelope.Offered] = []
        for case .attachment(let blobID) in items {
            guard (try? await isBlobReady(blobID: blobID)) == true,
                let record = try? await blobRecord(for: blobID)
            else { continue }
            offered.append(.init(item: .attachment(blobID: blobID), byteCount: record.byteCount))
        }
        guard !offered.isEmpty else { return }
        try? sendEnvelope(
            KeepTalkingBlobTransferEnvelope(
                context: contextID,
                sender: config.node,
                recipient: requester,
                step: .offer(offered)
            )
        )
    }

    /// Pulls each offered blob we still miss and aren't already pulling, from
    /// where our partial copy ends: blobs are content-addressed, so any
    /// holder's bytes continue any other's.
    private func pullOffered(
        _ offered: [KeepTalkingBlobTransferEnvelope.Offered],
        from holder: UUID,
        in contextID: UUID
    ) async {
        for offer in offered {
            guard case .attachment(let blobID) = offer.item,
                (try? await isBlobReady(blobID: blobID)) == false,
                await blobPulls.claim(blobID, from: holder)
            else { continue }
            connection.expectBlobStream(from: holder)
            do {
                try sendEnvelope(
                    KeepTalkingBlobTransferEnvelope(
                        context: contextID,
                        sender: config.node,
                        recipient: holder,
                        step: .pull(offer.item, offset: partialByteCount(blobID: blobID))
                    )
                )
            } catch {
                await blobPulls.finish(blobID)
                debug("blob pull failed blob=\(blobID) error=\(error.localizedDescription)")
            }
        }
    }

    private func partialByteCount(blobID: String) -> Int {
        guard let url = try? blobStore.partialFileURL(for: blobID),
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return 0 }
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Holder side

    /// Streams a pulled blob to `requester`, or tells it we can't.
    private func servePull(
        _ item: KeepTalkingBlobTransferEnvelope.Item,
        offset: Int,
        to requester: UUID,
        in contextID: UUID
    ) async {
        do {
            switch item {
                case .attachment(let blobID):
                    guard (try? await isBlobReady(blobID: blobID)) == true,
                        let record = try await blobRecord(for: blobID),
                        let relativePath = record.relativePath
                    else { throw KeepTalkingBlobStoreError.blobNotFound(blobID) }
                    try await streamAttachmentBlob(
                        blobStore.fileURL(forRelativePath: relativePath),
                        header: KeepTalkingBlobStreamHeader(
                            item: item,
                            offset: offset,
                            byteCount: record.byteCount,
                            mimeType: record.mimeType,
                            pathExtension: blobPathExtension(from: relativePath)
                        ),
                        to: requester
                    )
                case .oneTimeBlob(let transferID):
                    guard let entry = await oneTimeBlobOutbox.entry(for: transferID, requester: requester) else {
                        throw KeepTalkingOneTimeBlobError.unavailable(transferID)
                    }
                    try await streamOneTimeBlob(entry, transferID: transferID, fromChunk: offset)
            }
        } catch {
            debug(
                "blob serve failed item=\(item) to=\(requester.uuidString.prefix(8)) error=\(error.localizedDescription)"
            )
            try? sendEnvelope(
                KeepTalkingBlobTransferEnvelope(
                    context: contextID,
                    sender: config.node,
                    recipient: requester,
                    step: .unavailable(item)
                )
            )
        }
    }

    private func streamAttachmentBlob(
        _ fileURL: URL,
        header: KeepTalkingBlobStreamHeader,
        to requester: UUID
    ) async throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(header.offset, 0)))
        let writer = try await connection.openBlobStream(to: requester, header: try JSONEncoder().encode(header))
        do {
            while let chunk = try handle.read(upToCount: Self.blobStreamChunkSize), !chunk.isEmpty {
                try await writer.write(chunk)
            }
            try await writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
    }

    // MARK: - Receiver side

    /// A blob stream from `holder`. Only streams we pulled are read.
    func handleIncomingBlobStream(_ reader: any KeepTalkingBlobStreamReader, from holder: UUID) async {
        guard let header = try? JSONDecoder().decode(KeepTalkingBlobStreamHeader.self, from: reader.header) else {
            reader.cancel()
            return
        }
        switch header.item {
            case .attachment(let blobID):
                await receiveAttachmentBlob(blobID, header: header, reader: reader, from: holder)
            case .oneTimeBlob(let transferID):
                await receiveOneTimeBlob(transferID, header: header, reader: reader, from: holder)
        }
    }

    private func receiveAttachmentBlob(
        _ blobID: String,
        header: KeepTalkingBlobStreamHeader,
        reader: any KeepTalkingBlobStreamReader,
        from holder: UUID
    ) async {
        guard await blobPulls.isPulling(blobID, from: holder) else {
            reader.cancel()
            return
        }
        do {
            try await appendAttachmentStream(blobID, header: header, reader: reader)
        } catch {
            reader.cancel()
            debug("blob receive failed blob=\(blobID) error=\(error.localizedDescription)")
        }
        await blobPulls.finish(blobID)
    }

    /// Appends the stream to the blob's partial file from `header.offset`,
    /// then checks size and digest and promotes it to ready.
    private func appendAttachmentStream(
        _ blobID: String,
        header: KeepTalkingBlobStreamHeader,
        reader: any KeepTalkingBlobStreamReader
    ) async throws {
        let mimeType = header.mimeType ?? "application/octet-stream"
        let byteCount = max(header.byteCount, 0)
        // A stream continues our partial copy or starts it over; anything else
        // would splice bytes at the wrong place.
        let restart = header.offset == 0
        guard restart || header.offset == partialByteCount(blobID: blobID) else {
            throw KeepTalkingBlobStoreError.blobNotFound(blobID)
        }
        var received = header.offset
        var isFirstChunk = true
        let progressStep = max(Self.blobStreamChunkSize, byteCount / 100)
        while let chunk = try await reader.next() {
            let previous = received
            received = try blobStore.appendPartial(data: chunk, blobID: blobID, reset: restart && isFirstChunk)
            isFirstChunk = false
            guard received <= byteCount else { throw KeepTalkingBlobStoreError.blobNotFound(blobID) }
            try await upsertBlobRecord(
                blobID: blobID,
                relativePath: nil,
                availability: .partial,
                mimeType: mimeType,
                byteCount: byteCount,
                receivedBytes: received
            )
            if previous == header.offset || received / progressStep != previous / progressStep {
                notifyBlobAvailabilityChange(contextID: config.contextID, blobID: blobID)
            }
        }
        let pathExtension = normalizedPathExtension(header.pathExtension)
        let stored: (relativePath: String, fileURL: URL)
        if byteCount == 0 {
            stored = try blobStore.put(data: Data(), blobID: blobID, pathExtension: pathExtension)
        } else {
            let partial = try blobStore.partialData(blobID: blobID)
            guard partial.count == byteCount, hexDigest(for: partial) == blobID else {
                try? blobStore.removePartial(blobID: blobID)
                try await upsertBlobRecord(
                    blobID: blobID,
                    relativePath: nil,
                    availability: .missing,
                    mimeType: mimeType,
                    byteCount: byteCount,
                    receivedBytes: 0
                )
                notifyBlobAvailabilityChange(contextID: config.contextID, blobID: blobID)
                throw KeepTalkingBlobStoreError.blobNotFound(blobID)
            }
            stored = try blobStore.promotePartial(blobID: blobID, pathExtension: pathExtension)
        }
        try await upsertBlobRecord(
            blobID: blobID,
            relativePath: stored.relativePath,
            availability: .ready,
            mimeType: mimeType,
            byteCount: byteCount,
            receivedBytes: byteCount
        )
        notifyBlobAvailabilityChange(contextID: config.contextID, blobID: blobID)
    }

    // MARK: - Store reads

    private func recentAttachments(
        in contextID: UUID,
        since: Date
    ) async throws -> [KeepTalkingContextAttachment] {
        let attachments = try await KeepTalkingContextAttachment.query(
            on: localStore.database
        )
        .filter(\.$context.$id, .equal, contextID)
        .all()
        return
            attachments
            .filter { $0.createdAt >= since }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                if $0.sortIndex != $1.sortIndex {
                    return $0.sortIndex < $1.sortIndex
                }
                return ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
            }
    }

    private func blobRecord(
        for blobID: String
    ) async throws -> KeepTalkingBlobRecord? {
        try await KeepTalkingBlobRecord.query(on: localStore.database)
            .filter(\.$id, .equal, blobID)
            .first()
    }

    private func isBlobReady(blobID: String) async throws -> Bool {
        guard let blobRecord = try await blobRecord(for: blobID),
            blobRecord.availability == .ready
        else {
            return false
        }

        do {
            _ = try blobStore.read(
                relativePath: blobRecord.relativePath,
                blobID: blobID
            )
            return true
        } catch {
            return false
        }
    }

    private func blobPathExtension(from relativePath: String?) -> String? {
        normalizedPathExtension(
            relativePath.map {
                URL(fileURLWithPath: $0).pathExtension
            }
        )
    }

    private func normalizedPathExtension(_ pathExtension: String?) -> String? {
        guard
            let pathExtension = pathExtension?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !pathExtension.isEmpty
        else {
            return nil
        }
        return pathExtension
    }
}
