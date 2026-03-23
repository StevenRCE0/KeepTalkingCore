import Foundation
import LiveKitWebRTC

enum KeepTalkingFrameTransportCryptoError: LocalizedError {
    case packetCryptorUnavailable

    var errorDescription: String? {
        switch self {
            case .packetCryptorUnavailable:
                return "Failed to create packet cryptor for transport encryption."
        }
    }
}

enum KeepTalkingFrameTransportCrypto {
    static let ratchetSalt = Data("LKFrameEncryptionKey".utf8)
    static let uncryptedMagicBytes = Data("LK-ROCKS".utf8)
    static let ratchetWindowSize: Int32 = 0
    static let failureTolerance: Int32 = -1
    static let keyRingSize: Int32 = 16

    static func makeKeyProvider(secret: Data)
        -> LKRTCFrameCryptorKeyProvider
    {
        let keyProvider = LKRTCFrameCryptorKeyProvider(
            ratchetSalt: ratchetSalt,
            ratchetWindowSize: ratchetWindowSize,
            sharedKeyMode: true,
            uncryptedMagicBytes: uncryptedMagicBytes,
            failureTolerance: failureTolerance,
            keyRingSize: keyRingSize
        )
        keyProvider.setSharedKey(secret, with: 0)
        return keyProvider
    }

    static func makePacketCryptor(secret: Data) throws
        -> LKRTCDataPacketCryptor
    {
        guard let cryptor = LKRTCDataPacketCryptor(
            algorithm: .aesGcm,
            keyProvider: makeKeyProvider(secret: secret)
        ) else {
            throw KeepTalkingFrameTransportCryptoError.packetCryptorUnavailable
        }
        return cryptor
    }
}
