import Foundation

enum KeepTalkingBlobTransferError: LocalizedError {
    case frameTooShort
    case invalidHeaderLength
    case invalidPayloadLength

    var errorDescription: String? {
        switch self {
            case .frameTooShort:
                return "Blob transfer frame is too short."
            case .invalidHeaderLength:
                return "Blob transfer frame header length is invalid."
            case .invalidPayloadLength:
                return "Blob transfer frame payload length is invalid."
        }
    }
}

enum KeepTalkingBlobTransferCodec {
    private static let headerLengthByteCount = 4

    static func encode(_ frame: KeepTalkingBlobTransferFrame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let headerData = try encoder.encode(frame.header)

        var result = Data()
        var headerLength = UInt32(headerData.count).bigEndian
        withUnsafeBytes(of: &headerLength) { bytes in
            result.append(contentsOf: bytes)
        }
        result.append(headerData)
        result.append(frame.payload)
        return result
    }

    static func decode(_ data: Data) throws -> KeepTalkingBlobTransferFrame {
        guard data.count >= headerLengthByteCount else {
            throw KeepTalkingBlobTransferError.frameTooShort
        }

        let headerLength = data.prefix(headerLengthByteCount).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        let headerStart = headerLengthByteCount
        let headerEnd = headerStart + Int(headerLength)
        guard headerEnd <= data.count else {
            throw KeepTalkingBlobTransferError.invalidHeaderLength
        }

        let decoder = JSONDecoder()
        let header = try decoder.decode(
            KeepTalkingBlobTransferHeader.self,
            from: data.subdata(in: headerStart..<headerEnd)
        )
        let payload = data.suffix(from: headerEnd)

        if let chunkByteCount = header.chunkByteCount,
            chunkByteCount != payload.count
        {
            throw KeepTalkingBlobTransferError.invalidPayloadLength
        }
        if header.kind != .chunk, !payload.isEmpty {
            throw KeepTalkingBlobTransferError.invalidPayloadLength
        }

        return KeepTalkingBlobTransferFrame(
            header: header,
            payload: Data(payload)
        )
    }
}
