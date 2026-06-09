import Foundation

enum KeepTalkingBlobTransferKind: String, Codable, Sendable {
    case chunk
    case complete
}

struct KeepTalkingBlobTransferHeader: Codable, Sendable, Equatable {
    let kind: KeepTalkingBlobTransferKind
    let transferID: UUID
    let senderNodeID: UUID
    let recipientNodeID: UUID?
    let blobID: String
    let mimeType: String?
    let pathExtension: String?
    let byteCount: Int?
    let chunkIndex: Int?
    let chunkCount: Int?
    let chunkByteCount: Int?
    /// One-time blob (OTB) frame: bytes are an AES-GCM-encrypted chunk of a
    /// point-to-point ephemeral transfer keyed by `transferID`, NOT a context
    /// attachment. The receiver routes these to the ephemeral assembler — no
    /// blob store, no record, no broadcast. Optional so non-OTB frames omit it.
    var isEphemeral: Bool? = nil
}

struct KeepTalkingBlobTransferFrame: Sendable, Equatable {
    let header: KeepTalkingBlobTransferHeader
    let payload: Data
}
