//
//  KeepTalkingClient+BlobController.swift
//  KeepTalking
//
//  Created by 砚渤 on 24/03/2026.
//

import CryptoKit
import FluentKit
import Foundation

extension KeepTalkingClient {
    // Max payload size to keep entire frame well under 64KB SCTP limit
    private static let blobChunkSize = 32 * 1024

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

    func scheduleOutgoingBlobTransfers(
        for attachments: [KeepTalkingContextAttachment]
    ) {
        guard !attachments.isEmpty else {
            return
        }

        let uniqueAttachments = Dictionary(
            attachments.map { ($0.blobID, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.sortIndex < $1.sortIndex
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            for attachment in uniqueAttachments {
                do {
                    try await self.sendBlobFrames(
                        blobID: attachment.blobID,
                        recipientNodeID: nil
                    )
                } catch {
                    self.rtcClient.debug(
                        "blob push failed blob=\(attachment.blobID) error=\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func handleIncomingBlobFrameData(_ data: Data) async throws {
        let frame = try KeepTalkingBlobTransferCodec.decode(data)
        switch frame.header.kind {
            case .chunk:
                try await handleIncomingBlobChunk(frame)
            case .complete:
                try await handleIncomingBlobComplete(frame.header)
        }
    }

    func requestRecentMissingAttachmentBlobs(
        in contextID: UUID,
        since: Date
    ) async throws {
        guard let request = try await contextSyncAttachmentRequest(
            in: contextID,
            since: since
        ) else { return }

        try rtcClient.sendEnvelope(.contextSync(.attachmentRequest(request)))
    }

    func requestAttachmentBlobsIfNeeded(
        for attachments: [KeepTalkingContextAttachment],
        in contextID: UUID
    ) async throws {
        guard let request = try await attachmentRequest(
            for: attachments,
            in: contextID
        ) else { return }

        try rtcClient.sendEnvelope(.contextSync(.attachmentRequest(request)))
    }

    func respondToContextSyncAttachmentRequest(
        _ request: KeepTalkingContextSyncAttachmentRequest
    ) async throws {
        for hash in request.hashes {
            let mask = request.masks?[hash]
            guard let blobRecord = try await blobRecord(for: hash),
                blobRecord.availability == .ready
            else { continue }
            
            await blobTransportQueue.enqueue(
                blobID: hash,
                mask: mask,
                recipient: request.requester
            )
        }
        triggerBlobTransportQueue()
    }

    func hexDigest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func triggerBlobTransportQueue() {
        Task { [weak self] in
            guard let self else { return }
            let isSending = await self.blobTransportQueue.markSending()
            guard !isSending else { return }
            
            while let (blobID, request) = await self.blobTransportQueue.next() {
                do {
                    if request.recipients.isEmpty {
                        try await self.sendBlobFrames(blobID: blobID, mask: request.mask, recipientNodeID: nil)
                    } else {
                        for recipient in request.recipients {
                            try await self.sendBlobFrames(blobID: blobID, mask: request.mask, recipientNodeID: recipient)
                        }
                    }
                } catch {
                    self.rtcClient.debug("blob transport failed blob=\(blobID) error=\(error.localizedDescription)")
                }
            }
        }
    }

    func contextSyncAttachmentRequest(
        in contextID: UUID,
        since: Date
    ) async throws -> KeepTalkingContextSyncAttachmentRequest? {
        let attachments = try await recentAttachments(
            in: contextID,
            since: since
        )
        return try await attachmentRequest(
            for: attachments,
            in: contextID
        )
    }

    private func attachmentRequest(
        for attachments: [KeepTalkingContextAttachment],
        in contextID: UUID
    ) async throws -> KeepTalkingContextSyncAttachmentRequest? {
        let missing = try await missingAttachmentRequests(for: attachments)
        guard !missing.hashes.isEmpty else { return nil }

        return KeepTalkingContextSyncAttachmentRequest(
            context: contextID,
            requester: config.node,
            hashes: missing.hashes,
            masks: missing.masks.isEmpty ? nil : missing.masks
        )
    }

    private func missingAttachmentRequests(
        for attachments: [KeepTalkingContextAttachment]
    ) async throws -> (hashes: [String], masks: [String: Data]) {
        var requestedBlobIDs = Set<String>()
        var missingHashes: [String] = []
        var missingMasks: [String: Data] = [:]

        for attachment in attachments {
            guard requestedBlobIDs.insert(attachment.blobID).inserted else {
                continue
            }
            guard try await isBlobReady(blobID: attachment.blobID) == false else {
                continue
            }
            missingHashes.append(attachment.blobID)

            if let tryPartial = try? blobStore.partialData(blobID: attachment.blobID) {
                let receivedBytes = tryPartial.count
                let chunkIndex = receivedBytes / Self.blobChunkSize
                var maskData = Data(repeating: 0, count: (chunkIndex + 7) / 8)
                if chunkIndex > 0 {
                    let bitRemainder = chunkIndex % 8
                    if bitRemainder > 0 {
                        var lastByte: UInt8 = 0
                        for b in bitRemainder..<8 {
                            lastByte |= (1 << b)
                        }
                        maskData[maskData.count - 1] = lastByte
                    }
                }
                missingMasks[attachment.blobID] = maskData
            }
        }

        return (missingHashes, missingMasks)
    }

    private func handleIncomingBlobChunk(
        _ frame: KeepTalkingBlobTransferFrame
    ) async throws {
        let header = frame.header
        guard shouldAcceptBlobFrame(header) else {
            return
        }
        guard try await isBlobReady(blobID: header.blobID) == false else {
            return
        }

        let byteCount = max(header.byteCount ?? frame.payload.count, 0)
        let directive = await blobFrameProcessor.prepareChunk(
            blobID: header.blobID,
            transferID: header.transferID,
            chunkIndex: header.chunkIndex
        )
        guard case .accept(let reset) = directive else {
            rtcClient.debug(
                "ignored stale blob chunk blob=\(header.blobID) transfer=\(header.transferID.uuidString.lowercased()) chunk=\(header.chunkIndex ?? -1)"
            )
            return
        }
        let receivedBytes = try blobStore.appendPartial(
            data: frame.payload,
            blobID: header.blobID,
            reset: reset
        )
        try await upsertBlobRecord(
            blobID: header.blobID,
            relativePath: nil,
            availability: .partial,
            mimeType: header.mimeType ?? "application/octet-stream",
            byteCount: byteCount,
            receivedBytes: receivedBytes
        )
    }

    private func handleIncomingBlobComplete(
        _ header: KeepTalkingBlobTransferHeader
    ) async throws {
        guard shouldAcceptBlobFrame(header) else {
            return
        }
        guard try await isBlobReady(blobID: header.blobID) == false else {
            return
        }

        let byteCount = max(header.byteCount ?? 0, 0)
        guard
            await blobFrameProcessor.shouldAcceptComplete(
                blobID: header.blobID,
                transferID: header.transferID,
                byteCount: byteCount
            )
        else {
            rtcClient.debug(
                "ignored stale blob complete blob=\(header.blobID) transfer=\(header.transferID.uuidString.lowercased())"
            )
            return
        }
        let mimeType = header.mimeType ?? "application/octet-stream"
        let pathExtension = normalizedPathExtension(header.pathExtension)

        if byteCount == 0 {
            let stored = try blobStore.put(
                data: Data(),
                blobID: header.blobID,
                pathExtension: pathExtension
            )
            try await upsertBlobRecord(
                blobID: header.blobID,
                relativePath: stored.relativePath,
                availability: .ready,
                mimeType: mimeType,
                byteCount: 0,
                receivedBytes: 0
            )
            notifyBlobAvailabilityChange(
                contextID: config.contextID,
                blobID: header.blobID
            )
            await blobFrameProcessor.finish(
                blobID: header.blobID,
                transferID: header.transferID
            )
            return
        }

        let partialData = try blobStore.partialData(blobID: header.blobID)
        guard partialData.count == byteCount else {
            try await upsertBlobRecord(
                blobID: header.blobID,
                relativePath: nil,
                availability: .partial,
                mimeType: mimeType,
                byteCount: byteCount,
                receivedBytes: partialData.count
            )
            rtcClient.debug(
                "blob complete deferred blob=\(header.blobID) expected=\(byteCount) received=\(partialData.count)"
            )
            return
        }

        guard hexDigest(for: partialData) == header.blobID else {
            try? blobStore.removePartial(blobID: header.blobID)
            try await upsertBlobRecord(
                blobID: header.blobID,
                relativePath: nil,
                availability: .missing,
                mimeType: mimeType,
                byteCount: byteCount,
                receivedBytes: 0
            )
            await blobFrameProcessor.finish(
                blobID: header.blobID,
                transferID: header.transferID
            )
            rtcClient.debug("blob digest mismatch blob=\(header.blobID)")
            return
        }

        let stored = try blobStore.promotePartial(
            blobID: header.blobID,
            pathExtension: pathExtension
        )
        try await upsertBlobRecord(
            blobID: header.blobID,
            relativePath: stored.relativePath,
            availability: .ready,
            mimeType: mimeType,
            byteCount: byteCount,
            receivedBytes: byteCount
        )
        notifyBlobAvailabilityChange(
            contextID: config.contextID,
            blobID: header.blobID
        )
        await blobFrameProcessor.finish(
            blobID: header.blobID,
            transferID: header.transferID
        )
    }

    private func sendBlobFrames(
        blobID: String,
        mask: Data? = nil,
        recipientNodeID: UUID?
    ) async throws {
        guard let blobRecord = try await blobRecord(for: blobID),
            blobRecord.availability == .ready
        else {
            throw KeepTalkingBlobStoreError.blobNotFound(blobID)
        }

        try await sendBlobFrames(
            blobID: blobID,
            mimeType: blobRecord.mimeType,
            pathExtension: blobPathExtension(from: blobRecord.relativePath),
            expectedByteCount: blobRecord.byteCount,
            mask: mask,
            recipientNodeID: recipientNodeID,
            via: rtcClient.currentRoute()
        )
    }

    private func sendBlobFrames(
        blobID: String,
        mimeType: String,
        pathExtension: String?,
        expectedByteCount: Int,
        mask: Data? = nil,
        recipientNodeID: UUID?,
        via route: KeepTalkingTransportRoute
    ) async throws {
        guard let blobRecord = try await blobRecord(for: blobID),
            blobRecord.availability == .ready,
            let relativePath = blobRecord.relativePath
        else {
            throw KeepTalkingBlobStoreError.blobNotFound(blobID)
        }

        do {
            try await streamBlobFrames(
                blobID: blobID,
                mimeType: mimeType,
                pathExtension: pathExtension,
                expectedByteCount: expectedByteCount,
                mask: mask,
                recipientNodeID: recipientNodeID,
                via: route,
                relativePath: relativePath
            )
        } catch {
            guard route == .p2p else {
                throw error
            }
            rtcClient.debug(
                "blob transfer retrying on sfu blob=\(blobID) error=\(error.localizedDescription)"
            )
            try await streamBlobFrames(
                blobID: blobID,
                mimeType: mimeType,
                pathExtension: pathExtension,
                expectedByteCount: expectedByteCount,
                mask: mask,
                recipientNodeID: recipientNodeID,
                via: .sfu,
                relativePath: relativePath
            )
        }
    }

    private func streamBlobFrames(
        blobID: String,
        mimeType: String,
        pathExtension: String?,
        expectedByteCount: Int,
        mask: Data? = nil,
        recipientNodeID: UUID?,
        via route: KeepTalkingTransportRoute,
        relativePath: String
    ) async throws {
        let fileURL = blobStore.fileURL(forRelativePath: relativePath)
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        let fileByteCount =
            (fileAttributes[.size] as? NSNumber)?.intValue ?? expectedByteCount
        let byteCount = max(fileByteCount, expectedByteCount)
        let chunkCount =
            byteCount == 0
            ? 0
            : (byteCount + Self.blobChunkSize - 1) / Self.blobChunkSize
        let transferID = UUID()

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var chunkIndex = 0
        while true {
            let chunk = handle.readData(ofLength: Self.blobChunkSize)
            guard !chunk.isEmpty else {
                break
            }

            let shouldSend: Bool
            if let mask {
                let byteIndex = chunkIndex / 8
                let bitIndex = chunkIndex % 8
                if byteIndex < mask.count {
                    shouldSend = (mask[byteIndex] & (1 << bitIndex)) != 0
                } else {
                    shouldSend = true
                }
            } else {
                shouldSend = true
            }

            if shouldSend {
                let header = KeepTalkingBlobTransferHeader(
                    kind: .chunk,
                    transferID: transferID,
                    senderNodeID: config.node,
                    recipientNodeID: recipientNodeID,
                    blobID: blobID,
                    mimeType: mimeType,
                    pathExtension: pathExtension,
                    byteCount: byteCount,
                    chunkIndex: chunkIndex,
                    chunkCount: chunkCount,
                    chunkByteCount: chunk.count
                )
                try rtcClient.sendBlobData(
                    try KeepTalkingBlobTransferCodec.encode(
                        KeepTalkingBlobTransferFrame(
                            header: header,
                            payload: chunk
                        )
                    ),
                    via: route
                )
                // Sleep slightly between chunks to let WebRTC flush the SCTP send buffer
                // and prevent bufferedAmount from spiking without blocking the thread locally.
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
            chunkIndex += 1
        }

        // Brief sleep before the completion frame so the last chunk
        // has time to drain from the send buffer.
        try await Task.sleep(nanoseconds: 20_000_000)

        let completionHeader = KeepTalkingBlobTransferHeader(
            kind: .complete,
            transferID: transferID,
            senderNodeID: config.node,
            recipientNodeID: recipientNodeID,
            blobID: blobID,
            mimeType: mimeType,
            pathExtension: pathExtension,
            byteCount: byteCount,
            chunkIndex: nil,
            chunkCount: chunkCount,
            chunkByteCount: nil
        )
        try rtcClient.sendBlobData(
            try KeepTalkingBlobTransferCodec.encode(
                KeepTalkingBlobTransferFrame(
                    header: completionHeader,
                    payload: Data()
                )
            ),
            via: route
        )
    }

    private func recentAttachments(
        in contextID: UUID,
        since: Date
    ) async throws -> [KeepTalkingContextAttachment] {
        let attachments = try await KeepTalkingContextAttachment.query(
            on: localStore.database
        )
            .filter(\.$context.$id, .equal, contextID)
            .all()
        return attachments
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

    private func shouldAcceptBlobFrame(
        _ header: KeepTalkingBlobTransferHeader
    ) -> Bool {
        switch header.kind {
            case .chunk, .complete:
                guard let recipientNodeID = header.recipientNodeID else {
                    return true
                }
                return recipientNodeID == config.node
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
        guard let pathExtension = pathExtension?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !pathExtension.isEmpty else {
            return nil
        }
        return pathExtension
    }
}
