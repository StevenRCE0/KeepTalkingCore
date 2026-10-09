//
//  KeepTalkingCallAttestation.swift
//  KeepTalking
//
//  The verifiable-call seam. An executor's host hands every action call to an
//  injected `KeepTalkingCallAttestor` twice: before dispatch, to authorize the
//  exact call (evidence that travels with it), and after, to check what the
//  executor attested over its result. Nothing signs today — the default
//  attestor returns no evidence and reports every call `unattested` — but the
//  facts a billing or audit tier needs are bound here, and the evidence rides
//  the wire in opaque, scheme-tagged slots, so adding one is an injection,
//  not a protocol change.
//
//  The plugin host is the first adopter; node-to-node action calls are the
//  next. Statements carry the call's raw facts rather than digests, so each
//  scheme chooses its own canonicalization (`KeepTalkingCanonicalJSON` is the
//  cross-language one the Python and Swift SDKs agree on).
//

import Crypto
import Foundation
import MCP

/// The facts one action call binds: who asked which executor to run exactly
/// what, under which scope.
public struct KeepTalkingCallStatement: Sendable {
    public var invocationID: String
    /// The node hosting the executor (and, for billing, the merchant of record).
    public var hostNodeID: UUID
    public var callerNodeID: UUID
    public var contextID: UUID
    /// The executor serving the call — for the plugin host, the catalog id.
    public var executorID: UUID
    public var kindName: String
    public var tool: String?
    /// The action instance being called.
    public var actionID: UUID
    /// The instance's scope bag as stored.
    public var scope: Value?
    public var arguments: Value
    /// Resources provisioned for the call, as offered on the wire.
    public var resources: [KTPPResourceEntry]
    public var issuedAt: Date

    public init(
        invocationID: String,
        hostNodeID: UUID,
        callerNodeID: UUID,
        contextID: UUID,
        executorID: UUID,
        kindName: String,
        tool: String?,
        actionID: UUID,
        scope: Value?,
        arguments: Value,
        resources: [KTPPResourceEntry],
        issuedAt: Date
    ) {
        self.invocationID = invocationID
        self.hostNodeID = hostNodeID
        self.callerNodeID = callerNodeID
        self.contextID = contextID
        self.executorID = executorID
        self.kindName = kindName
        self.tool = tool
        self.actionID = actionID
        self.scope = scope
        self.arguments = arguments
        self.resources = resources
        self.issuedAt = issuedAt
    }
}

/// What the executor reported for one call.
public struct KeepTalkingCallResultStatement: Sendable {
    public var invocationID: String
    /// The result content exactly as the executor returned it.
    public var content: Value
    public var isError: Bool
    public var usage: [KTPPMeterUsage]

    public init(invocationID: String, content: Value, isError: Bool, usage: [KTPPMeterUsage]) {
        self.invocationID = invocationID
        self.content = content
        self.isError = isError
        self.usage = usage
    }
}

/// Opaque, scheme-tagged evidence: what one party's signer produced and the
/// other's verifier checks. The scheme ("kt.ed25519.v1", …) defines `payload`.
public struct KeepTalkingAttestation: Codable, Sendable, Hashable {
    public var scheme: String
    public var payload: Value

    public init(scheme: String, payload: Value) {
        self.scheme = scheme
        self.payload = payload
    }
}

public enum KeepTalkingAttestationVerdict: Sendable, Equatable {
    /// No evidence was asked for or given (the default attestor).
    case unattested
    case verified
    case rejected(reason: String)
}

/// Makes action calls verifiable. Inject one into an executor's host; the host
/// calls it for every call it dispatches.
public protocol KeepTalkingCallAttestor: Sendable {
    /// Evidence that the host authorized exactly `statement`, carried to the
    /// executor with the call. Nil sends the call without evidence. Throwing
    /// refuses the call.
    func authorize(_ statement: KeepTalkingCallStatement) async throws -> KeepTalkingAttestation?

    /// Checks the executor's evidence over `result` against the call it was
    /// bound to. Called for every result, with or without a receipt.
    func verify(
        receipt: KeepTalkingAttestation?,
        result: KeepTalkingCallResultStatement,
        statement: KeepTalkingCallStatement,
        authorization: KeepTalkingAttestation?
    ) async -> KeepTalkingAttestationVerdict
}

/// The default: calls carry no evidence and every result is `unattested`.
public struct KeepTalkingUnattestedCalls: KeepTalkingCallAttestor {
    public init() {}

    public func authorize(_ statement: KeepTalkingCallStatement) async throws -> KeepTalkingAttestation? {
        nil
    }

    public func verify(
        receipt: KeepTalkingAttestation?,
        result: KeepTalkingCallResultStatement,
        statement: KeepTalkingCallStatement,
        authorization: KeepTalkingAttestation?
    ) async -> KeepTalkingAttestationVerdict {
        .unattested
    }
}

// MARK: - Canonical JSON (JCS subset)

/// Deterministic JSON both SDKs produce byte-for-byte, for signing schemes.
/// Matches Python's
/// `json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`
/// for the value subset a signed payload may hold: null, bool, integer,
/// string, array, object. Doubles and binary data are rejected — the two
/// languages format them differently, so nothing float-shaped may be signed.
public enum KeepTalkingCanonicalJSON {
    public enum CanonicalError: LocalizedError {
        case nonIntegerNumber(Double)
        case unsupportedValue(String)

        public var errorDescription: String? {
            switch self {
                case .nonIntegerNumber(let value):
                    return "Canonical JSON forbids non-integer numbers (got \(value))."
                case .unsupportedValue(let kind):
                    return "Canonical JSON does not support \(kind) values."
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
