//
//  ProvisionPacking.swift
//  KeepTalking
//

import Foundation

public enum KeepTalkingProvisionPackingError: LocalizedError {
    case malformedPayload

    public var errorDescription: String? {
        switch self {
            case .malformedPayload:
                return "Packed provision data is malformed or unsupported."
        }
    }
}

/// Lightly obscures a provision payload so secrets (API keys, hosts) aren't
/// legible at a glance. This is obfuscation, **not** encryption — the transform
/// is reversible by anyone with this code; it only stops casual reading and
/// keyword-grepping of the raw file.
///
/// The earlier `NSKeyedArchiver` wrapper only changed the container: it embedded
/// the JSON verbatim, so the payload stayed in clear text inside the archive.
/// Here the payload bytes are run through a deterministic keystream XOR, which
/// removes all readable structure. Pure `Foundation` / Swift with no Apple-only
/// archiver, so it carries to the CLI and the cross-platform daemon unchanged.
///
/// Operates on raw `Data` (the caller owns JSON encode/decode), so it depends on
/// no model type. Internal: the public face is `KeepTalkingProvisionEncoder` /
/// `KeepTalkingProvisionDecoder`, which wrap JSON coding around this.
enum KeepTalkingProvisionPacking {
    /// Leading byte of the packed form. Distinct from JSON's `{` (0x7B) so an
    /// importer can tell the two apart by first byte alone.
    private static let marker: UInt8 = 0x62  // 'b'
    /// Format version, for future changes to the layout.
    private static let version: UInt8 = 0x01
    /// Header the packed bytes carry: `[marker, version]`.
    private static let header: [UInt8] = [marker, version]

    /// Keystream seed. Changing it invalidates previously packed files — fine,
    /// these are regenerated, not migrated.
    private static let keystreamSeed: UInt64 = 0x4B54_5072_6F76_3031  // "KTProv01"

    /// Whether `data` is in the packed form rather than raw JSON.
    static func isPacked(_ data: Data) -> Bool {
        data.first == marker
    }

    /// Packs a raw payload (e.g. profile JSON): `[marker, version]` followed by
    /// the keystream-XOR'd bytes.
    static func pack(_ payload: Data) -> Data {
        var out = Data(header)
        out.append(scramble(payload))
        return out
    }

    /// Returns the raw payload: unscrambles a packed blob, or passes the bytes
    /// through unchanged when they aren't packed (already raw JSON). Lets callers
    /// run any inbound file through one sniffing entry point.
    static func unpack(_ data: Data) throws -> Data {
        guard isPacked(data) else { return data }
        guard data.count >= header.count, data[data.startIndex + 1] == version else {
            throw KeepTalkingProvisionPackingError.malformedPayload
        }
        return scramble(data.dropFirst(header.count))
    }

    /// Symmetric keystream XOR — applying it twice yields the original bytes.
    /// The keystream is a SplitMix64 step seeded by `keystreamSeed`, so it has no
    /// short period and won't expose the periodicity a single repeating key would.
    private static func scramble<S: Sequence>(_ bytes: S) -> Data where S.Element == UInt8 {
        var state = keystreamSeed
        var out = Data()
        for byte in bytes {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            out.append(byte ^ UInt8(z & 0xFF))
        }
        return out
    }
}
