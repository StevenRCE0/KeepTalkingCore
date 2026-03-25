import Foundation
import Testing

@testable import KeepTalkingSDK

struct BlobTransferCodecTests {
    @Test("blob chunk frames encode metadata before raw bytes and round-trip cleanly")
    func chunkFrameRoundTrip() throws {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let frame = KeepTalkingBlobTransferFrame(
            header: KeepTalkingBlobTransferHeader(
                kind: .chunk,
                transferID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                senderNodeID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                recipientNodeID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                blobID: String(repeating: "c", count: 64),
                mimeType: "image/png",
                pathExtension: "png",
                byteCount: 4,
                chunkIndex: 0,
                chunkCount: 1,
                chunkByteCount: payload.count
            ),
            payload: payload
        )

        let encoded = try KeepTalkingBlobTransferCodec.encode(frame)
        let decoded = try KeepTalkingBlobTransferCodec.decode(encoded)

        #expect(decoded == frame)
    }

    @Test("non-chunk blob frames reject unexpected raw payload bytes")
    func nonChunkPayloadIsRejected() throws {
        let encoded = try KeepTalkingBlobTransferCodec.encode(
            KeepTalkingBlobTransferFrame(
                header: KeepTalkingBlobTransferHeader(
                    kind: .complete,
                    transferID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
                    senderNodeID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    recipientNodeID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    blobID: String(repeating: "d", count: 64),
                    mimeType: "application/pdf",
                    pathExtension: "pdf",
                    byteCount: 12,
                    chunkIndex: nil,
                    chunkCount: nil,
                    chunkByteCount: nil
                ),
                payload: Data()
            )
        )
        let malformed = encoded + Data([0x99])

        #expect(throws: KeepTalkingBlobTransferError.invalidPayloadLength) {
            try KeepTalkingBlobTransferCodec.decode(malformed)
        }
    }
}
