//
//  PluginProtocolModels.swift
//  KeepTalking
//
//  KTPP v1 — the native KeepTalking Plugin Protocol (see DESIGN_PLUGIN_ACTIONS.md).
//  Frame envelope, payload models, canonical JSON, and signing helpers shared by
//  the host actor and (as the normative reference) the companion SDKs.
//

import Crypto
import Foundation
import MCP

// MARK: - Frame envelope

/// One NDJSON line on the socket. Requests/notifications carry `id` + `kind`;
/// responses carry `re` (the request's id) with kind `res` or `error`.
public struct KTPPFrame: Codable, Sendable {
    public var v: Int
    public var id: String?
    public var re: String?
    public var kind: String
    public var payload: Value?

    public init(v: Int = 1, id: String? = nil, re: String? = nil, kind: String, payload: Value? = nil) {
        self.v = v
        self.id = id
        self.re = re
        self.kind = kind
        self.payload = payload
    }

    public static func request(_ kind: String, payload: Value?) -> KTPPFrame {
        KTPPFrame(id: UUID.v7().uuidString.lowercased(), kind: kind, payload: payload)
    }

    public static func response(to request: KTPPFrame, payload: Value?) -> KTPPFrame {
        KTPPFrame(re: request.id, kind: KTPPFrameKind.res, payload: payload)
    }

    public static func errorResponse(to request: KTPPFrame, code: String, message: String) -> KTPPFrame {
        KTPPFrame(
            re: request.id,
            kind: KTPPFrameKind.error,
            payload: .object(["code": .string(code), "message": .string(message)])
        )
    }
}

public enum KTPPFrameKind {
    public static let res = "res"
    public static let error = "error"
    public static let hello = "plugin.hello"
    public static let helloProof = "plugin.hello.proof"
    public static let pair = "plugin.pair"
    public static let pairConfirm = "plugin.pair.confirm"
    public static let kindsGet = "plugin.kinds.get"
    public static let kindsChanged = "plugin.kinds.changed"
    public static let callRequest = "plugin.call.request"
    public static let callCancel = "plugin.call.cancel"
    /// Reverse direction (plugin → host). Reserved namespace from the design
    /// doc's §12.1; this is its first member: a plugin asking the USER to
    /// create an instance of one of its kinds. It proposes, never creates.
    public static let hostActionCreate = "host.action.create"
}

public enum KTPPConstants {
    public static let protocolVersion = 1
    public static let pairDomain = "kt.plugin.pair.v1"
    public static let helloDomain = "kt.plugin.hello.v1"
    public static let callDomain = "kt.plugin.call.v1"
    public static let receiptDomain = "kt.plugin.receipt.v1"
    public static let endorseDomain = "kt.plugin.endorse.v1"
    public static let signatureAlgorithm = "ed25519"
    /// `KTPPHello.role` value for the unified companion runtime app — the only
    /// role whose catalogs may endorse other plugins' pairings.
    public static let companionRole = "companion"
}

// MARK: - Handshake payloads

public struct KTPPPluginInfo: Codable, Sendable, Equatable {
    public var name: String
    public var vendor: String
    public var version: String

    public init(name: String, vendor: String, version: String) {
        self.name = name
        self.vendor = vendor
        self.version = version
    }
}

/// plugin → host, first frame on every connection.
public struct KTPPHello: Codable, Sendable {
    public var ktppVersion: Int
    public var identityPublicKey: String  // base64 raw Ed25519
    public var catalogID: String?  // lowercase UUID, absent before first pairing
    public var pluginInfo: KTPPPluginInfo
    /// "companion" for the unified companion runtime app; nil for plugins.
    public var role: String?
    /// Companion-signed endorsement of this plugin's identity (raw signed
    /// object, domain `kt.plugin.endorse.v1`). A valid endorsement from a
    /// paired companion catalog auto-approves this plugin's pairing — one
    /// consent for the companion, N cleanly separated plugin catalogs.
    public var endorsement: Value?
    public var features: [String]?
}

/// host → plugin, response payload to `plugin.hello` (resume path) — or
/// `{status: "pair"}` when pairing is required first.
public struct KTPPHelloReply: Codable, Sendable {
    public var status: String  // "challenge" | "pair"
    public var hostNonce: String?  // base64, present when status == "challenge"
}

public struct KTPPHelloProof: Codable, Sendable {
    public var signature: String  // base64 Ed25519 over the hello transcript
}

/// host → plugin request payload for `plugin.pair`.
public struct KTPPPairRequest: Codable, Sendable {
    public var ktppVersion: Int
    public var hostNodeID: String
    public var hostIdentityPublicKey: String
    public var catalogID: String
    public var hostNonce: String
}

/// plugin → host response payload to `plugin.pair`.
public struct KTPPPairResponse: Codable, Sendable {
    public var pluginInfo: KTPPPluginInfo
    public var identityPublicKey: String
    public var pluginNonce: String
    public var manifestHash: String
    public var transcriptSignature: String
}

public struct KTPPPairConfirm: Codable, Sendable {
    public var transcriptSignature: String
}

// MARK: - Kind registration payloads

public struct KTPPMeterDeclaration: Codable, Sendable, Equatable {
    public var name: String
    public var quantum: String
    public var description: String?
}

/// One registered action kind — the template the user instantiates (§4.3 of the
/// design doc). `inputSchema`/`scopeSchema` are JSON Schema fragments; `defaultScope`
/// makes one-click instantiation possible.
public struct KTPPKindDeclaration: Codable, Sendable, Equatable {
    public var kindName: String
    public var displayName: String
    public var indexDescription: String
    public var inputSchema: Value?
    public var scopeSchema: Value?
    public var defaultScope: Value?
    public var subTools: [KTPPSubTool]?
    public var remoteAuthorisable: Bool?
    public var blockingAuthorisation: Bool?
}

public struct KTPPSubTool: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?
    public var inputSchema: Value?
}

public struct KTPPKindsResult: Codable, Sendable {
    public var manifestVersion: String
    public var manifestHash: String
    public var kinds: [KTPPKindDeclaration]
    public var meters: [KTPPMeterDeclaration]?
    public var priceSheet: Value?
}

// MARK: - Call payloads

/// host → plugin request payload for `plugin.call.request`. The signed
/// `authorization` (and later the plugin's signed receipt) travel as raw `Value`
/// objects so signatures verify over exactly what crossed the wire.
public struct KTPPCallRequest: Codable, Sendable {
    public var requestID: String
    public var contextID: String
    public var callerNodeID: String
    public var kindName: String
    public var tool: String?
    public var arguments: Value  // object
    public var instance: KTPPInstanceRef
    public var authorization: Value  // signed KTPPCallAuthorization object
    public var grant: Value?
}

public struct KTPPInstanceRef: Codable, Sendable {
    public var id: String
    public var scope: Value?
    public var scopeHash: String
}

/// plugin → host response payload to `plugin.call.request`.
public struct KTPPCallResult: Codable, Sendable {
    public var requestID: String
    public var content: Value  // array of Tool.Content-shaped objects
    public var isError: Bool
    public var receipt: Value?  // signed KTPPUsageReceipt object
}

/// plugin → host request payload for `host.action.create`.
public struct KTPPActionCreateRequest: Codable, Sendable {
    public var kindName: String
    public var suggestedName: String?
    public var reason: String?
    public var suggestedScope: Value?
}

/// host → plugin response: what the user decided.
public struct KTPPActionCreateResult: Codable, Sendable {
    public var status: String  // "created" | "declined" | "unsupported"
    public var actionID: String?
    public var message: String?
}

// MARK: - Canonical JSON (JCS-subset)

/// Deterministic JSON serialization both sides sign over. Matches Python's
/// `json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`
/// for the value subset KTPP permits: null, bool, integer, string, array, object.
/// Doubles and binary data are rejected — nothing float-shaped may enter a signed
/// payload (usage units are integers in the meter's declared quantum).
public enum KTPPCanonicalJSON {
    public enum CanonicalError: LocalizedError {
        case nonIntegerNumber(Double)
        case unsupportedValue(String)

        public var errorDescription: String? {
            switch self {
                case .nonIntegerNumber(let value):
                    return "KTPP canonical JSON forbids non-integer numbers (got \(value))."
                case .unsupportedValue(let kind):
                    return "KTPP canonical JSON does not support \(kind) values."
            }
        }
    }

    public static func canonicalData(_ value: Value) throws -> Data {
        var out = ""
        try serialize(value, into: &out)
        return Data(out.utf8)
    }

    public static func sha256Hex(_ value: Value) throws -> String {
        let digest = SHA256.hash(data: try canonicalData(value))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func serialize(_ value: Value, into out: inout String) throws {
        switch value {
            case .null:
                out += "null"
            case .bool(let flag):
                out += flag ? "true" : "false"
            case .int(let number):
                out += String(number)
            case .double(let number):
                // Tolerate doubles that decoded from integral JSON literals.
                guard number.truncatingRemainder(dividingBy: 1) == 0,
                    number.magnitude < 9_007_199_254_740_992,  // 2^53 — JSON-safe integers
                    !number.isNaN, !number.isInfinite
                else {
                    throw CanonicalError.nonIntegerNumber(number)
                }
                out += String(Int64(number))
            case .string(let string):
                serialize(string: string, into: &out)
            case .data:
                throw CanonicalError.unsupportedValue("binary data")
            case .array(let items):
                out += "["
                for (index, item) in items.enumerated() {
                    if index > 0 { out += "," }
                    try serialize(item, into: &out)
                }
                out += "]"
            case .object(let fields):
                // Sort by Unicode scalar sequence — identical to Python's
                // code-point string ordering under sort_keys=True.
                let sortedKeys = fields.keys.sorted { lhs, rhs in
                    lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars) { $0.value < $1.value }
                }
                out += "{"
                for (index, key) in sortedKeys.enumerated() {
                    if index > 0 { out += "," }
                    serialize(string: key, into: &out)
                    out += ":"
                    try serialize(fields[key]!, into: &out)
                }
                out += "}"
        }
    }

    /// Python-json compatible string escaping with `ensure_ascii=False`:
    /// short escapes for the usual control characters, `\u00xx` (lowercase hex)
    /// for the rest below 0x20, raw UTF-8 for everything else.
    private static func serialize(string: String, into out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\u{08}": out += "\\b"
                case "\u{09}": out += "\\t"
                case "\u{0A}": out += "\\n"
                case "\u{0C}": out += "\\f"
                case "\u{0D}": out += "\\r"
                default:
                    if scalar.value < 0x20 {
                        out += String(format: "\\u%04x", scalar.value)
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
            }
        }
        out += "\""
    }
}

// MARK: - Signing helpers

public enum KTPPCrypto {
    /// Signs the canonical bytes of `payload` (which must NOT contain a
    /// `signature` field yet) and returns the base64 signature.
    public static func sign(_ payload: Value, with key: Curve25519.Signing.PrivateKey) throws -> String {
        let data = try KTPPCanonicalJSON.canonicalData(payload)
        return try key.signature(for: data).base64EncodedString()
    }

    /// Verifies a signed payload object: strips `signature`, canonicalizes the
    /// rest, and checks the Ed25519 signature against `publicKeyB64`.
    public static func verifySignedObject(_ signed: Value, publicKeyB64: String) throws -> Bool {
        guard case .object(var fields) = signed,
            case .string(let signatureB64)? = fields["signature"],
            let signature = Data(base64Encoded: signatureB64),
            let keyData = Data(base64Encoded: publicKeyB64)
        else { return false }
        fields["signature"] = nil
        let unsigned = Value.object(fields)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        return key.isValidSignature(signature, for: try KTPPCanonicalJSON.canonicalData(unsigned))
    }

    /// Attaches a signature to an unsigned payload object.
    public static func attachSignature(to payload: Value, with key: Curve25519.Signing.PrivateKey) throws -> Value {
        guard case .object(var fields) = payload else {
            throw KTPPCanonicalJSON.CanonicalError.unsupportedValue("non-object signing payload")
        }
        fields["signature"] = .string(try sign(payload, with: key))
        return .object(fields)
    }

    /// The pairing transcript both sides sign (domain `kt.plugin.pair.v1`).
    public static func pairTranscript(
        hostNodeID: String,
        hostIdentityPublicKey: String,
        catalogID: String,
        hostNonce: String,
        pluginInfo: KTPPPluginInfo,
        pluginIdentityPublicKey: String,
        pluginNonce: String,
        manifestHash: String
    ) -> Value {
        .object([
            "domain": .string(KTPPConstants.pairDomain),
            "ktppVersion": .int(KTPPConstants.protocolVersion),
            "hostNodeID": .string(hostNodeID),
            "hostIdentityPublicKey": .string(hostIdentityPublicKey),
            "catalogID": .string(catalogID),
            "hostNonce": .string(hostNonce),
            "pluginName": .string(pluginInfo.name),
            "pluginVendor": .string(pluginInfo.vendor),
            "pluginVersion": .string(pluginInfo.version),
            "pluginIdentityPublicKey": .string(pluginIdentityPublicKey),
            "pluginNonce": .string(pluginNonce),
            "manifestHash": .string(manifestHash),
        ])
    }

    /// The endorsement payload a companion signs over one of its plugins'
    /// identities (domain `kt.plugin.endorse.v1`). Attach a signature with
    /// `attachSignature(to:with:)` using the companion identity key.
    public static func endorsementPayload(
        endorserCatalogID: String,
        endorserPublicKey: String,
        pluginPublicKey: String,
        pluginName: String,
        issuedAtMS: Int
    ) -> Value {
        .object([
            "domain": .string(KTPPConstants.endorseDomain),
            "alg": .string(KTPPConstants.signatureAlgorithm),
            "endorserCatalogID": .string(endorserCatalogID),
            "endorserPublicKey": .string(endorserPublicKey),
            "pluginPublicKey": .string(pluginPublicKey),
            "pluginName": .string(pluginName),
            "issuedAtMS": .int(issuedAtMS),
        ])
    }

    /// The hello transcript the plugin signs on resume (domain `kt.plugin.hello.v1`).
    public static func helloTranscript(
        hostNonce: String,
        catalogID: String,
        identityPublicKey: String
    ) -> Value {
        .object([
            "domain": .string(KTPPConstants.helloDomain),
            "hostNonce": .string(hostNonce),
            "catalogID": .string(catalogID),
            "identityPublicKey": .string(identityPublicKey),
        ])
    }

    /// Human-checkable fingerprint of an identity key: first 16 hex chars of
    /// SHA-256, grouped ("ab12 cd34 ef56 7890").
    public static func fingerprint(publicKeyB64: String) -> String {
        guard let data = Data(base64Encoded: publicKeyB64) else { return "invalid-key" }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16)
        return stride(from: 0, to: hex.count, by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }.joined(separator: " ")
    }

    public static func randomNonce() -> String {
        Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }
}

// MARK: - Value ↔ Codable bridging

extension Value {
    /// Encodes a Codable payload struct into a `Value` tree (wire order is
    /// irrelevant; only signed payloads need canonical treatment and those are
    /// hand-built as `Value` objects).
    public static func wrap<T: Encodable>(_ payload: T) throws -> Value {
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Frame line coding

public enum KTPPFrameCoding {
    public static func encodeLine(_ frame: KTPPFrame) throws -> String {
        let data = try JSONEncoder().encode(frame)
        guard let line = String(data: data, encoding: .utf8) else {
            throw KTPPCanonicalJSON.CanonicalError.unsupportedValue("non-UTF8 frame")
        }
        return line + "\n"
    }

    public static func decodeLine(_ line: some StringProtocol) throws -> KTPPFrame {
        try JSONDecoder().decode(KTPPFrame.self, from: Data(line.utf8))
    }
}
