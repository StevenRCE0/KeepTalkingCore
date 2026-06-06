//
//  ProvisionCoding.swift
//  KeepTalking
//

import Foundation

/// Encodes values to the provision wire format — JSON, optionally wrapped in the
/// obscured (packed) form. Mirrors `JSONEncoder` so call sites read the familiar
/// way: `KeepTalkingProvisionEncoder().encode(bundle)`.
public struct KeepTalkingProvisionEncoder {
    /// When `true`, `encode(_:)` emits the obscured packed form rather than plain
    /// JSON. Per-call control is available via `encode(_:obscured:)`.
    public var obscured: Bool

    public init(obscured: Bool = false) {
        self.obscured = obscured
    }

    /// Encodes using the encoder's `obscured` setting.
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        try encode(value, obscured: obscured)
    }

    /// Encodes, enforcing the obscuring mode for this call regardless of the
    /// encoder's `obscured` setting.
    public func encode<T: Encodable>(_ value: T, obscured: Bool) throws -> Data {
        let json = try JSONEncoder().encode(value)
        return obscured ? KeepTalkingProvisionPacking.pack(json) : json
    }

    /// base64url string of the encoded bytes (unpadded) — for embedding in a URL
    /// query, e.g. `ktprovision://import?payload=…`. base64 is the outer layer
    /// applied *after* coding, so the payload carries whichever form `encode`
    /// produced: plain JSON or obscured. Honors the encoder's `obscured` setting.
    public func encodePayload<T: Encodable>(_ value: T) throws -> String {
        provisionBase64URLString(from: try encode(value))
    }

    /// Payload variant that enforces the obscuring mode for this call.
    public func encodePayload<T: Encodable>(_ value: T, obscured: Bool) throws -> String {
        provisionBase64URLString(from: try encode(value, obscured: obscured))
    }
}

/// Decodes values from the provision wire format. Mirrors `JSONDecoder`. By
/// default it sniffs the form (raw JSON vs. packed); `decode(_:from:obscured:)`
/// pins the form when the source is known.
public struct KeepTalkingProvisionDecoder {
    public init() {}

    /// Auto-detects the form by leading byte, then decodes. The lenient default —
    /// accepts either raw JSON or a packed payload.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: KeepTalkingProvisionPacking.unpack(data))
    }

    /// Decodes, enforcing the form: `obscured: true` requires the packed form (a
    /// non-packed payload throws `KeepTalkingProvisionPackingError`); `obscured:
    /// false` reads raw JSON without unpacking. Use when the source's form is
    /// known and a mismatch should fail loudly instead of being silently accepted.
    public func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        obscured: Bool
    ) throws -> T {
        let json: Data
        if obscured {
            guard KeepTalkingProvisionPacking.isPacked(data) else {
                throw KeepTalkingProvisionPackingError.malformedPayload
            }
            json = try KeepTalkingProvisionPacking.unpack(data)
        } else {
            json = data
        }
        return try JSONDecoder().decode(type, from: json)
    }

    /// Decodes from a base64url payload string (as produced by the encoder).
    /// Strips the base64 transport layer, then sniffs the bytes' form like
    /// `decode(_:from:)`.
    public func decode<T: Decodable>(_ type: T.Type, fromPayload payload: String) throws -> T {
        guard let data = provisionData(fromBase64URL: payload) else {
            throw KeepTalkingProvisionPackingError.malformedPayload
        }
        return try decode(type, from: data)
    }

    /// Payload variant that pins the post-base64 form (see `decode(_:from:obscured:)`).
    public func decode<T: Decodable>(
        _ type: T.Type,
        fromPayload payload: String,
        obscured: Bool
    ) throws -> T {
        guard let data = provisionData(fromBase64URL: payload) else {
            throw KeepTalkingProvisionPackingError.malformedPayload
        }
        return try decode(type, from: data, obscured: obscured)
    }
}

// MARK: - base64url transport

/// base64url, unpadded — URL-safe alphabet, no `=` padding. The outer transport
/// layer wrapped around (de)coded bytes for `ktprovision://` links.
private func provisionBase64URLString(from data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func provisionData(fromBase64URL payload: String) -> Data? {
    var base64 =
        payload
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder > 0 {
        base64 += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: base64)
}
