//
//  KeepTalkingBlobFrameProcessor.swift
//  KeepTalking
//
//  Created by 砚渤 on 24/03/2026.
//

import Foundation

actor KeepTalkingBlobFrameProcessor {
    enum ChunkDirective {
        case accept(reset: Bool)
        case ignore
    }

    private var lastOperation: Task<Void, Never>?
    private var activeTransfers: [String: UUID] = [:]

    func process(
        _ operation: @Sendable @escaping () async throws -> Void
    ) async throws {
        let previous = lastOperation
        let task = Task<Void, Error> {
            _ = await previous?.result
            try await operation()
        }
        lastOperation = Task {
            _ = try? await task.value
        }
        try await task.value
    }

    func prepareChunk(
        blobID: String,
        transferID: UUID,
        chunkIndex: Int?
    ) -> ChunkDirective {
        guard let chunkIndex else {
            return .ignore
        }
        if chunkIndex == 0 {
            activeTransfers[blobID] = transferID
            return .accept(reset: true)
        }
        if activeTransfers[blobID] == nil {
            activeTransfers[blobID] = transferID
            return .accept(reset: false)
        }
        guard activeTransfers[blobID] == transferID else {
            return .ignore
        }
        return .accept(reset: false)
    }

    func shouldAcceptComplete(
        blobID: String,
        transferID: UUID,
        byteCount: Int
    ) -> Bool {
        guard byteCount > 0 else {
            return true
        }
        return activeTransfers[blobID] == transferID
    }

    func finish(blobID: String, transferID: UUID) {
        guard activeTransfers[blobID] == transferID else {
            return
        }
        activeTransfers.removeValue(forKey: blobID)
    }
}
