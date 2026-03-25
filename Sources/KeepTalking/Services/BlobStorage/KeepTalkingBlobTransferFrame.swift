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
}

struct KeepTalkingBlobTransferFrame: Sendable, Equatable {
    let header: KeepTalkingBlobTransferHeader
    let payload: Data
}
