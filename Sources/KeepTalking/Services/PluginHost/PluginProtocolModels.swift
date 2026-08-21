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
    /// Companion → host: open the "add action" UI without a pre-selected kind.
    public static let hostUIAddAction = "host.ui.addAction"
    /// Plugin → host: one bounded AI turn on the host's ACT connector, valid
    /// only while servicing an in-flight call (resources design doc §4).
    public static let hostActRequest = "host.act.request"
    /// Plugin → host notification: a short explanatory note for the in-flight
    /// call, published into the caller's trace and backfed to the ACT agent.
    public static let hostActElucidate = "host.act.elucidate"
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
    /// Fresh per-connection nonce. When present on a resume, the host's ok
    /// reply advertises its current identity key with a signature over this
    /// nonce (domain `kt.plugin.hello.host.v1`), letting the SDK re-pin a
    /// legitimately rotated host key instead of failing every authorization.
    public var pluginNonce: String?
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

/// The FIXED capability vocabulary a kind may declare (resources design doc
/// §7.5 resolution): a closed enum, never freeform strings — plugins are the
/// "controlled" surface. Unknown tokens in a declaration are dropped, never
/// interpreted. The vocabulary grows here, one deliberate case at a time.
/// (File IO is NOT a capability — it is governed by the kind's declared
/// `objects`, which carry direction and drive staging/slots directly.)
public enum KTPPPluginCapability: String, CaseIterable, Sendable {
    /// May issue `host.act.request` while servicing a call. Enforced at three
    /// levels, all required: this declaration (kind ceiling), the instance
    /// scope's optional `capabilities` narrowing, and the catalog's
    /// user-consent toggle (`allowsACT`).
    case act
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
    /// Directioned file objects this kind consumes/produces (§3.3 of the
    /// resources design doc). Absent = the kind does no file IO.
    public var objects: [KTPPObjectDeclaration]?
    /// Capabilities from the FIXED `KTPPPluginCapability` vocabulary this kind
    /// needs. The declaration is the kind-level ceiling; instances may narrow
    /// it via the reserved `capabilities` scope key.
    public var capabilities: [String]?
    /// Legacy disclosure bit, superseded by `capabilities: ["act"]` — still
    /// honored (it implies the act capability) so early declarations keep
    /// working.
    public var usesACT: Bool?
    public var remoteAuthorisable: Bool?
    public var blockingAuthorisation: Bool?

    /// The recognized declared capability set: `capabilities` filtered to the
    /// fixed vocabulary (unknown tokens dropped — a plugin bug or a newer
    /// plugin's token must not widen anything), plus the legacy `usesACT`
    /// alias for `.act`.
    public var declaredCapabilities: Set<KTPPPluginCapability> {
        var set = Set((capabilities ?? []).compactMap(KTPPPluginCapability.init(rawValue:)))
        if usesACT == true { set.insert(.act) }
        return set
    }
}

public struct KTPPSubTool: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?
    public var inputSchema: Value?
}

/// One directioned SVO file object a kind declares — the wire form of
/// `KeepTalkingActionObject` (all declared objects are files; non-file
/// parameters belong in `inputSchema`). Materialized onto the instance
/// descriptor at instantiation, which is what flips `acceptsFileInput`
/// and drives input staging / output-slot minting for plugin calls.
public struct KTPPObjectDeclaration: Codable, Sendable, Equatable {
    public var name: String
    /// "input" | "output" | "inout" (`KeepTalkingResourceDirection` raw values).
    public var direction: String
    public var description: String?

    public init(name: String, direction: String, description: String? = nil) {
        self.name = name
        self.direction = direction
        self.description = description
    }
}

public struct KTPPKindsResult: Codable, Sendable {
    public var manifestVersion: String
    public var manifestHash: String
    public var kinds: [KTPPKindDeclaration]
    public var meters: [KTPPMeterDeclaration]?
    public var priceSheet: Value?
}

// MARK: - Resource payloads (KTPP v1.1)

/// One resource provisioned for a call — the wire projection of a
/// `KTResourceManifest.Entry` (`envKey` → `handle`, canonicalized path carried
/// verbatim). This IS the skill emission re-targeted: a skill subprocess gets
/// `$KT_<HANDLE>=<path>` env vars; an attached plugin process gets the same
/// pairs in the call frame. No file bytes ever cross the socket — the plugin
/// SDK does direct local IO on the path and OBSCURES it from handler code,
/// which sees only handles + streams (DESIGN_PLUGIN_RESOURCES_ACT.md §3.2).
public struct KTPPResourceEntry: Codable, Sendable, Equatable {
    /// `KT_<KIND>_<HEX>` — identical to the manifest entry's `envKey`, so the
    /// orchestrating agent, a skill's `$KT_…` env var, and a plugin entry all
    /// name the same resource with the same token.
    public var handle: String
    /// Resource family: "attachment" | "otb" | "fs".
    public var kind: String
    /// `.read` (input) or `.write` (output slot the host harvests after the
    /// call) — typed at the wire boundary; encodes as "read"/"write".
    public var direction: KTResourceManifest.Direction
    /// Sanitized display name (host-side control-character strip).
    public var name: String
    /// The declared SVO object this resource binds to, when any.
    public var objectName: String?
    /// Resolved absolute path on this host — SDK-private on the plugin side,
    /// never surfaced to handler code. Absent for fs-reached entries (none in
    /// v1). Local-socket only; node-to-node envelopes never carry it.
    public var path: String?
    /// Directory resources (collection slots / staged dirs) take child files.
    public var isDirectory: Bool

    public init(
        handle: String,
        kind: String,
        direction: KTResourceManifest.Direction,
        name: String,
        objectName: String? = nil,
        path: String? = nil,
        isDirectory: Bool
    ) {
        self.handle = handle
        self.kind = kind
        self.direction = direction
        self.name = name
        self.objectName = objectName
        self.path = path
        self.isDirectory = isDirectory
    }
}

/// The `resources` block on `plugin.call.request`.
public struct KTPPResources: Codable, Sendable, Equatable {
    public var entries: [KTPPResourceEntry]

    public init(entries: [KTPPResourceEntry]) {
        self.entries = entries
    }

    /// The single-sourced projection: every wire entry derives from a manifest
    /// entry here, so the two vocabularies can never diverge (the same rule the
    /// manifest enforces between `environmentVariables()` and `promptBlock()`).
    /// Returns nil for an absent/empty manifest — the field is then omitted
    /// from the frame entirely.
    public init?(manifest: KTResourceManifest?) {
        guard let manifest, !manifest.entries.isEmpty else { return nil }
        entries = manifest.entries.map { entry in
            KTPPResourceEntry(
                handle: entry.envKey,
                kind: entry.kind.agentFamily,
                direction: entry.direction,
                name: entry.displayName,
                objectName: entry.objectName,
                path: entry.path?.path,
                isDirectory: entry.isDirectory)
        }
    }
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
    /// Resources provisioned for this call (path-free; §3.1 of the resources
    /// design doc). When present, the authorization binds it as `resourcesHash`.
    public var resources: KTPPResources?
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

// MARK: - ACT payloads (KTPP v1.1)

/// plugin → host request payload for `host.act.request` — one bounded AI turn
/// on the HOST's ACT connector, bound to an in-flight call. Execution is
/// always local to the plugin's host node; remote callers contribute
/// attribution only (resources design doc §4.2).
public struct KTPPActRequest: Codable, Sendable {
    /// The in-flight `plugin.call.request` id this turn is bound to.
    public var requestID: String
    public var task: String
    /// Extra system guidance, appended to the host's plugin-ACT preamble.
    public var system: String?
    /// Resource handles FROM THIS CALL's `resources` block whose (text) content
    /// the host injects into the transcript.
    public var attachments: [String]?
    /// "text" (default) | "json".
    public var expects: String?
    public var maxOutputTokens: Int?
}

public struct KTPPActUsage: Codable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// host → plugin response payload to `host.act.request`.
public struct KTPPActResult: Codable, Sendable {
    public var text: String
    public var thinking: String?
    public var model: String
    public var usage: KTPPActUsage?

    public init(
        text: String, thinking: String? = nil, model: String,
        usage: KTPPActUsage? = nil
    ) {
        self.text = text
        self.thinking = thinking
        self.model = model
        self.usage = usage
    }
}

/// plugin → host NOTIFICATION payload for `host.act.elucidate` — a short
/// explanatory note for the in-flight call. Never answered; narration must
/// not be able to fail a call.
public struct KTPPActElucidation: Codable, Sendable {
    public var requestID: String
    public var message: String
    public var detail: String?
}

/// plugin → host request payload for `host.action.create`.
public struct KTPPActionCreateRequest: Codable, Sendable {
    public var kindName: String
    public var suggestedName: String?
    public var reason: String?
    public var suggestedScope: Value?
}

/// plugin → host request payload for `host.ui.addAction` — Companion asks the
/// host to open the "add action" UI, optionally pre-scoped to a kind/plugin.
/// Both fields optional: an empty payload opens the unscoped flow.
public struct KTPPUIAddActionRequest: Codable, Sendable {
    public var kindName: String?
    public var pluginName: String?

    public init(kindName: String? = nil, pluginName: String? = nil) {
        self.kindName = kindName
        self.pluginName = pluginName
    }
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
