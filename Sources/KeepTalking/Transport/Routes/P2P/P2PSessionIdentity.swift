import Crypto
import Foundation
import NIOSSL
import SwiftASN1
import X509

/// Per-session self-signed TLS material for a P2P blob channel.
///
/// Generates a fresh P-256 keypair and a short-lived (24h) self-signed
/// X.509 certificate each time. Replaces the previous static PKCS#12
/// blob that shipped in source — no private-key material lives in the
/// SDK binary anymore, and every peer's listener presents a unique
/// cert with a key that never leaves process memory.
///
/// Phase 1 (this commit): no pubkey pinning. The initiator still uses
/// `certificateVerification = .none`. TLS provides channel
/// confidentiality only; peer authenticity continues to live in the
/// KT envelope layer (pubkey-bound message crypto).
///
/// Phase 2 (see DESIGN_P2P_TLS.md): embed the KT node pubkey in a SAN
/// `otherName` extension and enforce it with a custom verification
/// callback on both sides.
enum P2PSessionIdentity {
    struct Material {
        let certificate: NIOSSLCertificate
        let privateKey: NIOSSLPrivateKey
    }

    static func make() throws -> Material {
        let p256 = P256.Signing.PrivateKey()
        let certKey = Certificate.PrivateKey(p256)

        let name = try DistinguishedName {
            CommonName("kt-p2p-session")
        }

        let now = Date()
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: certKey.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(24 * 3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
            },
            issuerPrivateKey: certKey
        )

        var serializer = DER.Serializer()
        try cert.serialize(into: &serializer)
        let certDER = serializer.serializedBytes

        let nioCert = try NIOSSLCertificate(bytes: certDER, format: .der)
        let nioKey = try NIOSSLPrivateKey(
            bytes: Array(p256.pemRepresentation.utf8),
            format: .pem
        )
        return Material(certificate: nioCert, privateKey: nioKey)
    }
}
