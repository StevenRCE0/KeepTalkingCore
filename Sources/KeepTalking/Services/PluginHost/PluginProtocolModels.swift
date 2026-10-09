//
//  PluginProtocolModels.swift
//  KeepTalking
//
//  KTPP payload models — kinds, scope options, resources, calls, ACT — shared
//  by the host actor and (as the normative reference) the companion SDKs.
//  The v2 session envelopes that carry them over gRPC are in
//  Wire/KTPPWireMessages.swift.
//

import Foundation
import MCP

// MARK: - Plugin identity

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
    /// May send `RequestAct` while servicing a call. Enforced at three
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
    /// Resources this kind exposes, declared beside its tools in MCP's
    /// `resources/list` shape — for a plugin wrapping an MCP server, the
    /// server resources it forwards. Read through the plugin-resources meta
    /// tool; never fetched behind a call.
    public var resources: [KTPPResourceDeclaration]?
    /// Directioned file objects this kind consumes/produces (§3.3 of the
    /// resources design doc). Absent = the kind does no file IO.
    public var objects: [KTPPObjectDeclaration]?
    /// Capabilities from the FIXED `KTPPPluginCapability` vocabulary this kind
    /// needs. The declaration is the kind-level ceiling; instances may narrow
    /// it via the reserved `capabilities` scope key.
    public var capabilities: [String]?
    public var remoteAuthorisable: Bool?
    public var blockingAuthorisation: Bool?

    /// The recognized declared capability set: `capabilities` filtered to the
    /// fixed vocabulary (unknown tokens dropped — a plugin bug or a newer
    /// plugin's token must not widen anything).
    public var declaredCapabilities: Set<KTPPPluginCapability> {
        Set((capabilities ?? []).compactMap(KTPPPluginCapability.init(rawValue:)))
    }
}

public struct KTPPSubTool: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?
    public var inputSchema: Value?
}

// MARK: - Scope options

/// How one scope key of a kind offers choices in the instance form, read from
/// the key's schema fragment: `x-ktpp-options: {live, allowsCustom}` for
/// choices the plugin supplies at form time, or standard JSON Schema `enum`
/// (`items.enum` for arrays) for fixed ones.
public struct KTPPScopeOptionsSpec: Sendable, Equatable {
    /// The schema keyword a scope key declares live options with.
    public static let keyword = "x-ktpp-options"

    /// The plugin answers scope-options requests for this key.
    public var isLive: Bool
    /// Values outside the offered choices may be entered by hand. Defaults to
    /// true for live options and false for a fixed `enum`.
    public var allowsCustom: Bool
    /// The key takes a list of choices (`type: array`) rather than one.
    public var isMultiple: Bool
    /// Choices fixed in the schema itself.
    public var fixedChoices: [Value]

    /// The spec for `key`, or nil when the key offers no choices.
    public static func parse(scopeSchema: Value?, key: String) -> KTPPScopeOptionsSpec? {
        guard case .object(let fields)? = scopeSchema,
            case .object(let field)? = fields[key]
        else { return nil }
        let isMultiple = field["type"] == .string("array")
        var enumeration = field["enum"]
        if isMultiple, case .object(let items)? = field["items"] {
            enumeration = items["enum"]
        }
        var fixedChoices: [Value] = []
        if case .array(let values)? = enumeration { fixedChoices = values }
        var isLive = false
        var allowsCustom = fixedChoices.isEmpty
        if case .object(let options)? = field[keyword] {
            isLive = options["live"] == .bool(true)
            if case .bool(let flag)? = options["allowsCustom"] {
                allowsCustom = flag
            } else if isLive {
                allowsCustom = true
            }
        }
        guard isLive || !fixedChoices.isEmpty else { return nil }
        return KTPPScopeOptionsSpec(
            isLive: isLive, allowsCustom: allowsCustom,
            isMultiple: isMultiple, fixedChoices: fixedChoices)
    }
}

/// Host → plugin `scopeOptions` payload. `scope` is the form's
/// current bag, so one key's choices may depend on another's; `query`
/// narrows a long list plugin-side.
public struct KTPPScopeOptionsRequest: Codable, Sendable {
    public var kindName: String
    public var key: String
    public var scope: [String: Value]
    public var query: String?
}

/// One choice a plugin offers for a scope key. Display data only: the chosen
/// `value` lands in the instance's scope bag, which the host signs into every
/// call and the plugin re-enforces — an option grants nothing by itself.
public struct KTPPScopeOption: Codable, Sendable, Hashable, Identifiable {
    public struct Icon: Codable, Sendable, Hashable {
        /// An SF Symbol name.
        public var symbol: String?
        /// An application bundle identifier; the host draws that app's icon.
        public var app: String?
    }

    public var value: Value
    public var label: String
    public var detail: String?
    /// Section the choice is listed under ("Open now", "Installed", …).
    public var group: String?
    public var icon: Icon?
    /// A short warning shown with the choice ("can run any shell command").
    public var caution: String?

    public var id: Value { value }

    public init(
        value: Value, label: String, detail: String? = nil, group: String? = nil,
        icon: Icon? = nil, caution: String? = nil
    ) {
        self.value = value
        self.label = label
        self.detail = detail
        self.group = group
        self.icon = icon
        self.caution = caution
    }

    /// Plugin text is untrusted display data: trimmed to sane lengths, and a
    /// choice whose value isn't a plain scalar or whose label is empty is
    /// dropped rather than rendered.
    func sanitized() -> KTPPScopeOption? {
        switch value {
            case .string, .int, .bool: break
            default: return nil
        }
        func trim(_ text: String?, _ limit: Int) -> String? {
            guard let text else { return nil }
            let single = text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return single.isEmpty ? nil : String(single.prefix(limit))
        }
        guard let label = trim(label, 120) else { return nil }
        return KTPPScopeOption(
            value: value, label: label, detail: trim(detail, 200),
            group: trim(group, 60),
            icon: icon.map { Icon(symbol: trim($0.symbol, 80), app: trim($0.app, 200)) },
            caution: trim(caution, 200))
    }
}

public struct KTPPScopeOptionsResult: Codable, Sendable {
    public var options: [KTPPScopeOption]
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
}

// MARK: - Declared resources

/// One resource a kind declares, in MCP's `Resource` shape (`resources/list`).
public struct KTPPResourceDeclaration: Codable, Sendable, Equatable {
    public var uri: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?
    public var size: Int?

    public init(
        uri: String, name: String, title: String? = nil, description: String? = nil,
        mimeType: String? = nil, size: Int? = nil
    ) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.size = size
    }

    public var displayName: String { title ?? name }

    /// Plugin text is untrusted display data: single-line, quote-free and
    /// trimmed; a resource with no uri or name is dropped.
    func sanitized() -> KTPPResourceDeclaration? {
        func clean(_ text: String?, _ limit: Int) -> String? {
            guard let text else { return nil }
            let line = text.components(separatedBy: .newlines).joined(separator: " ")
                .components(separatedBy: CharacterSet(charactersIn: "\"`$")).joined()
                .trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : String(line.prefix(limit))
        }
        guard !uri.isEmpty, uri.count <= 2_048, let name = clean(name, 120) else { return nil }
        return KTPPResourceDeclaration(
            uri: uri, name: name, title: clean(title, 120),
            description: clean(description, 400), mimeType: clean(mimeType, 120),
            size: size.map { max(0, $0) })
    }
}

public struct KTPPResourceReadRequest: Codable, Sendable {
    public var kindName: String
    public var uri: String
}

/// MCP's `resources/read` result, verbatim.
public struct KTPPResourceReadResult: Codable, Sendable {
    public var contents: [Resource.Content]
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

/// The `resources` block on a `call`.
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

/// host → plugin `call` payload. `authorization` is the host attestor's
/// evidence for exactly this call (absent unless an attestor is injected —
/// see KeepTalkingCallAttestation.swift).
public struct KTPPCallRequest: Codable, Sendable {
    public var requestID: String
    public var contextID: String
    public var callerNodeID: String
    public var kindName: String
    public var tool: String?
    public var arguments: Value  // object
    public var instance: KTPPInstanceRef
    /// Resources provisioned for this call (§3.1 of the resources design doc).
    public var resources: KTPPResources?
    public var authorization: KeepTalkingAttestation?
}

public struct KTPPInstanceRef: Codable, Sendable {
    public var id: String
    public var scope: Value?
}

/// Units of one declared meter a call consumed, reported by the plugin.
public struct KTPPMeterUsage: Codable, Sendable, Equatable {
    public var meter: String
    /// Whole units of the meter's declared quantum.
    public var units: Int

    public init(meter: String, units: Int) {
        self.meter = meter
        self.units = units
    }
}

/// plugin → host `callResult` payload. `receipt` is the plugin's evidence over
/// this result, bound to the call's `authorization`, when its attestor
/// produces one.
public struct KTPPCallResult: Codable, Sendable {
    public var requestID: String
    public var content: Value  // array of Tool.Content-shaped objects
    public var isError: Bool
    public var usage: [KTPPMeterUsage]?
    public var receipt: KeepTalkingAttestation?
}

// MARK: - ACT payloads (KTPP v1.1)

/// plugin → host `RequestAct` payload — one bounded AI turn
/// on the HOST's ACT connector, bound to an in-flight call. Execution is
/// always local to the plugin's host node; remote callers contribute
/// attribution only (resources design doc §4.2).
public struct KTPPActRequest: Codable, Sendable {
    /// The in-flight call's `requestID` this turn is bound to.
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

/// host → plugin answer to `RequestAct`.
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

/// plugin → host `elucidation` notification — a short
/// explanatory note for the in-flight call. Never answered; narration must
/// not be able to fail a call.
public struct KTPPActElucidation: Codable, Sendable {
    public var requestID: String
    public var message: String
    public var detail: String?
}

/// plugin → host `ProposeAction` payload.
public struct KTPPActionCreateRequest: Codable, Sendable {
    /// The proposing plugin (its `Hello.name`); it may only propose its own
    /// kinds.
    public var pluginName: String
    public var kindName: String
    public var suggestedName: String?
    public var reason: String?
    public var suggestedScope: Value?
}

/// plugin → host `OpenAddAction` payload — Companion asks the
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
