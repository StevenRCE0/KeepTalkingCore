import FluentKit
import Foundation

/// Describes the concrete resource an action can operate on.
public enum KeepTalkingActionResource: Codable, Sendable {
    case urls([URL])
    case filePaths([URL])
    case command([[String]])
}

/// Wraps an action resource with human-readable context for catalog displays.
public struct KeepTalkingActionResourceWithDescription: Codable, Sendable {
    public var description: String
    public var resource: KeepTalkingActionResource

    public init(description: String, resource: KeepTalkingActionResource) {
        self.description = description
        self.resource = resource
    }
}

/// Which way data flows for an action object — the distinction the bare verb
/// can't express (a skill can take a file AND produce one).
public enum KeepTalkingResourceDirection: String, Codable, Sendable, Hashable {
    /// Consumed by the action — flows IN (caller → executor).
    case input
    /// Produced by the action — flows OUT (executor → caller).
    case output
    /// Read-modify-write — both.
    case inputOutput = "inout"
}

/// The "O" in subject·verb·object, upgraded: a typed resource plus the direction
/// it flows and the call argument it binds to. A descriptor carries a *set* of
/// these so an action can declare, e.g., one `.input` file and one `.output`
/// file. For `.filePaths` objects this single declaration drives one-time-blob
/// routing (direction → which way bytes stream), sandbox grants (input → read,
/// output → write), and the acceptance gate (only declared objects are spooled).
public struct KeepTalkingActionObject: Codable, Sendable {
    /// Binds to a call argument, e.g. "input" / "source" / "path".
    public var name: String?
    public var description: String
    public var resource: KeepTalkingActionResource
    public var direction: KeepTalkingResourceDirection

    public init(
        name: String? = nil,
        description: String = "",
        resource: KeepTalkingActionResource,
        direction: KeepTalkingResourceDirection
    ) {
        self.name = name
        self.description = description
        self.resource = resource
        self.direction = direction
    }

    /// Whether this object is a file (the only resource OTB transfers today).
    public var isFile: Bool {
        if case .filePaths = resource { return true }
        return false
    }
}

/// An atomic operation that can be performed within an action's scope — the
/// single capability vocabulary. Structural cases name an operation class;
/// `.named` names a specific resource (an MCP tool, a primitive scope key) that
/// a grant can allowlist. "All"/unrestricted is deliberately NOT a verb — it
/// lives on the grant (`KeepTalkingActionScope`), so an action's capability can
/// never be confused with the breadth of a grant.
public enum KeepTalkingActionVerb: Sendable, Hashable {
    case read
    case write
    case execute
    case network
    case grep
    case ls
    case callTool
    /// A specific named resource (MCP tool name, primitive scope key). Invisible
    /// to the sandbox compiler — it narrows runtime call-gating only.
    case named(String)

    /// The structural (non-`named`) cases. Replaces synthesized `CaseIterable`,
    /// which an associated-value enum cannot provide.
    public static let structuralCases: [KeepTalkingActionVerb] =
        [.read, .write, .execute, .network, .grep, .ls, .callTool]
}

/// Plain `rawValue`/`init?(rawValue:)` members (NOT a `RawRepresentable`
/// conformance) so existing string consumers (skill command names, planner verb
/// parsing, tool-entry labels) keep working unchanged. Crucially this is NOT a
/// `RawRepresentable` conformance: that would make synthesized `Equatable`/
/// `Hashable` key off `rawValue`, so `.named("read")` would compare EQUAL to the
/// structural `.read` (and a primitive scope key named "read" would collide).
/// As plain members, synthesized equality stays per-case.
/// `init?(rawValue:)` recognizes ONLY structural tokens (returns `nil`
/// otherwise — `.named` is never produced from a raw string); `rawValue`
/// returns the bare name for `.named`.
extension KeepTalkingActionVerb {
    public init?(rawValue: String) {
        switch rawValue {
            case "read": self = .read
            case "write": self = .write
            case "execute": self = .execute
            case "network": self = .network
            case "grep": self = .grep
            case "ls": self = .ls
            case "call-tool": self = .callTool
            default: return nil
        }
    }

    public var rawValue: String {
        switch self {
            case .read: return "read"
            case .write: return "write"
            case .execute: return "execute"
            case .network: return "network"
            case .grep: return "grep"
            case .ls: return "ls"
            case .callTool: return "call-tool"
            case .named(let name): return name
        }
    }
}

/// Custom `Codable`, kept separate from `rawValue` so `.named("read")` cannot
/// collide with the structural `read` token: structural verbs encode as their
/// bare string; `.named(x)` encodes as `{"named": x}`.
extension KeepTalkingActionVerb: Codable {
    private enum NamedCodingKey: String, CodingKey { case named }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
            let raw = try? single.decode(String.self),
            let verb = KeepTalkingActionVerb(rawValue: raw)
        {
            self = verb
            return
        }
        let keyed = try decoder.container(keyedBy: NamedCodingKey.self)
        self = .named(try keyed.decode(String.self, forKey: .named))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
            case .named(let name):
                var keyed = encoder.container(keyedBy: NamedCodingKey.self)
                try keyed.encode(name, forKey: .named)
            default:
                var single = encoder.singleValueContainer()
                try single.encode(rawValue)
        }
    }
}

/// Describes the verb portion of an action descriptor.
///
/// When `verbs` is populated, the descriptor drives sandbox policy compilation.
/// When `nil`, the descriptor is display-only (legacy behavior).
public struct KeepTalkingActionWithDescription: Codable, Sendable {
    public var description: String
    public var verbs: Set<KeepTalkingActionVerb>?

    public init(description: String, verbs: Set<KeepTalkingActionVerb>? = nil) {
        self.description = description
        self.verbs = verbs
    }
}

/// Provides subject-action-object metadata used to explain an action to users and AI planners.
///
/// When populated with typed verbs and a concrete object resource, the descriptor also drives
/// sandbox policy compilation — the verbs determine what operations are allowed, and the object
/// resource defines the scope boundary enforced by the platform sandbox backend.
public struct KeepTalkingActionDescriptor: Codable, Sendable {
    public var subject: KeepTalkingActionResourceWithDescription?
    public var action: KeepTalkingActionWithDescription?
    public var object: KeepTalkingActionResourceWithDescription?
    /// Directioned object set — the upgraded "O" in SVO. Additive alongside the
    /// legacy singular `object` (which remains for non-file actions and the
    /// existing sandbox path); file routing/grants/gating key off this. `nil`
    /// for actions that declare no directioned objects.
    public var objects: [KeepTalkingActionObject]?
    /// Environment variables required by this action at execution time.
    public var environment: [String: String]?
    /// Named base directories the action needs access to (e.g. "project_root").
    /// Values are absolute paths on the host, resolved before sandbox compilation.
    public var directories: [String: URL]?
    /// Per-directory data-flow direction, keyed by the SAME label as
    /// `directories`. Drives per-directory sandbox write grants: `.input` →
    /// read-only, `.output`/`.inputOutput` → read + write. A label absent from
    /// this map falls back to the legacy rule (read always; write only when the
    /// policy's verbs include `.write`). `nil` preserves pre-direction behavior.
    public var directoryDirections: [String: KeepTalkingResourceDirection]?

    public init(
        subject: KeepTalkingActionResourceWithDescription? = nil,
        action: KeepTalkingActionWithDescription? = nil,
        object: KeepTalkingActionResourceWithDescription? = nil,
        objects: [KeepTalkingActionObject]? = nil,
        environment: [String: String]? = nil,
        directories: [String: URL]? = nil,
        directoryDirections: [String: KeepTalkingResourceDirection]? = nil
    ) {
        self.subject = subject
        self.action = action
        self.object = object
        self.objects = objects
        self.environment = environment
        self.directories = directories
        self.directoryDirections = directoryDirections
    }

    /// Whether this descriptor carries enough information to compile a sandbox policy.
    public var hasSandboxConstraints: Bool {
        action?.verbs != nil
            && (object?.resource != nil || directories?.isEmpty == false
                || objects?.isEmpty == false)
    }

    /// File objects flowing a given direction (the unit OTB transfers + grants
    /// key off). `.inputOutput` objects appear in both input and output queries.
    public func fileObjects(
        direction: KeepTalkingResourceDirection
    ) -> [KeepTalkingActionObject] {
        (objects ?? []).filter { object in
            guard object.isFile else { return false }
            switch direction {
                case .input:
                    return object.direction == .input || object.direction == .inputOutput
                case .output:
                    return object.direction == .output || object.direction == .inputOutput
                case .inputOutput:
                    return object.direction == .inputOutput
            }
        }
    }
}

/// The lifetime of a granted action scope.
public enum KeepTalkingActionGrantDuration: String, Codable, Sendable {
    /// Valid for a single execution only.
    case once
    /// Valid until the current session (context connection) ends.
    case session
    /// Persisted across sessions.
    case standing
}

/// A recorded grant that associates a descriptor with its approval metadata.
public struct KeepTalkingActionGrant: Codable, Sendable, Identifiable {
    public var id: UUID
    public var descriptor: KeepTalkingActionDescriptor
    public var duration: KeepTalkingActionGrantDuration
    public var grantedAt: Date
    public var grantedByNodeID: UUID

    public init(
        id: UUID = UUID.v7(),
        descriptor: KeepTalkingActionDescriptor,
        duration: KeepTalkingActionGrantDuration,
        grantedAt: Date = .now,
        grantedByNodeID: UUID
    ) {
        self.id = id
        self.descriptor = descriptor
        self.duration = duration
        self.grantedAt = grantedAt
        self.grantedByNodeID = grantedByNodeID
    }
}

public protocol KeepTalkingActionBundle: Identifiable, Codable, Sendable {
    var id: UUID { get set }
    var name: String { get set }
    var indexDescription: String { get set }
}

/// Persisted action model that binds an executable payload to a node.
public final class KeepTalkingAction: Model, @unchecked Sendable {

    public static let schema: String = "kt_actions"

    public enum Payload: Codable, Sendable {
        case mcpBundle(KeepTalkingMCPBundle)
        case skill(KeepTalkingSkillBundle)
        case primitive(KeepTalkingPrimitiveBundle)
        case semanticRetrieval(KeepTalkingSemanticRetrievalBundle)
        case filesystem(KeepTalkingFilesystemBundle)
        case acp(KeepTalkingACPBundle)
        /// An instance minted from a plugin-provided **Catalogue** kind.
        case plugin(KeepTalkingPluginBundle)

        public var isSemanticRetrieval: Bool {
            if case .semanticRetrieval = self { return true }
            return false
        }

        public var semanticRetrievalBundle: KeepTalkingSemanticRetrievalBundle? {
            if case .semanticRetrieval(let bundle) = self { return bundle }
            return nil
        }

        public var filesystemBundle: KeepTalkingFilesystemBundle? {
            if case .filesystem(let bundle) = self { return bundle }
            return nil
        }

        /// Whether `GrantPermissionEditor` would render any controls for this
        /// payload — i.e. whether per-grant permission narrowing is meaningful.
        /// False for skill / semanticRetrieval (no editor) and for primitives
        /// whose action kind declares an empty `scopeSchema`.
        public var hasGrantPermissionEditor: Bool {
            switch self {
                case .filesystem, .mcpBundle: return true
                case .primitive(let bundle): return !bundle.action.scopeSchema.isEmpty
                // ACP has no per-grant narrowing UI in v1 (owner grants are
                // unrestricted; the action's compiled sandbox is the ceiling).
                case .skill, .semanticRetrieval, .acp: return false
                // Narrowing is meaningful whenever the kind exposes sub-tools;
                // the editor keys off the Catalogue declaration, not the row.
                case .plugin: return true
            }
        }

        public var typeName: String {
            switch self {
                case .mcpBundle:
                    "MCP"
                case .skill:
                    "Skill"
                case .primitive:
                    "Primitive"
                case .semanticRetrieval:
                    "Memory"
                case .filesystem:
                    "File"
                case .acp:
                    "ACP"
                case .plugin:
                    "Catalogue"
            }
        }
    }

    public var isSemanticRetrieval: Bool {
        payload.isSemanticRetrieval == true
    }

    public var actionLabel: String {
        if case .mcpBundle(let bundle) = payload {
            return bundle.name
        }
        if case .skill(let bundle) = payload {
            return bundle.name
        }
        if case .primitive(let bundle) = payload {
            return bundle.name
        }
        if case .filesystem(let bundle) = payload {
            return bundle.name
        }
        if case .acp(let bundle) = payload {
            return bundle.name
        }
        if case .plugin(let bundle) = payload {
            return bundle.name
        }

        return id?.uuidString.uppercased() ?? "Unknown Action"
    }

    public var beautifulLabel: String {
        actionLabel.beautifulName
    }

    /// Whether this action consumes a file as input — i.e. a caller may attach
    /// one-time blob (OTB) `inputTransfers` that the executor stages for it.
    /// This is the single gate for accepting pushed file bytes: a node never
    /// spools a transfer for an action that doesn't accept one. Today only
    /// skills consume files (their scripts read `$KT_ATTACHMENTS`); the property
    /// is intentionally general so other payload types can opt in later.
    public var acceptsFileInput: Bool {
        switch payload {
            case .skill:
                return true
            case .mcpBundle, .primitive, .filesystem, .semanticRetrieval, .acp, .plugin:
                return false
        }
    }

    public var wakeDescription: String {
        let description =
            descriptor?.action?.description
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !description.isEmpty {
            return description
        }
        if !beautifulLabel.isEmpty {
            return beautifulLabel
        }
        return id?.uuidString.lowercased() ?? "Remote action"
    }

    @ID(key: .id)
    public var id: UUID?

    @OptionalParent(key: "node")
    public var node: KeepTalkingNode?

    @Field(key: "descriptor")
    public var descriptor: KeepTalkingActionDescriptor?

    @Field(key: "payload")
    public var payload: Payload

    @Field(key: "remote_authorisable")
    public var remoteAuthorisable: Bool?

    @Field(key: "blocking_authorisation")
    public var blockingAuthorisation: Bool?

    @OptionalField(key: "disabled")
    public var disabled: Bool?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "last_used", on: .none)
    public var lastUsed: Date?

    /// Creates an empty model instance for Fluent.
    public init() {}

    /// Creates a persisted action with its runtime payload and authorization settings.
    ///
    /// - Parameters:
    ///   - id: Stable action identifier.
    ///   - payload: Executable action payload.
    ///   - remoteAuthorisable: Whether a remote node may authorize this action.
    ///   - blockingAuthorisation: Whether execution waits for authorization to complete.
    public init(
        id: UUID = UUID.v7(),
        payload: Payload,
        remoteAuthorisable: Bool,
        blockingAuthorisation: Bool
    ) {
        self.id = id
        self.payload = payload
        self.remoteAuthorisable = remoteAuthorisable
        self.blockingAuthorisation = blockingAuthorisation
    }
}

public enum KeepTalkingActionType: String, CaseIterable, Identifiable, Hashable {
    case http = "HTTP"
    case stdio = "STDIO"
    case skill = "Skill"
    case primitive = "Primitive"
    case shortcut = "Shortcut"
    case filesystem = "Filesystem"
    case acp = "ACP"
    /// Kinds contributed by paired plugins — the Catalogue group.
    case catalogue = "Catalogue"

    public var id: Self { self }

    public var icon: String {
        switch self {
            case .http: "network"
            case .stdio: "terminal"
            case .skill: "text.document"
            case .primitive: "bolt.fill"
            case .shortcut: "square.2.layers.3d.bottom.filled"
            case .filesystem: "folder.fill"
            case .acp: "wand.and.rays"
            case .catalogue: "heart.square.fill"
        }
    }

    public var shortDescription: String {
        switch self {
            case .http: "Connect to an MCP server over HTTP or HTTPS"
            case .stdio: "Run a local process via standard I/O"
            case .skill: "Load a skill bundle from a local folder"
            case .primitive: "Built-in system capabilities"
            case .shortcut: "Run a macOS Shortcut by name"
            case .filesystem: "Expose a local filesystem path"
            case .acp: "Delegate tasks to an external coding agent (ACP)"
            case .catalogue: "Ready-made actions from plugins in your Companion"
        }
    }
}

extension String {
    public var beautifulName: String {
        self
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized(with: .autoupdatingCurrent)
    }
}
