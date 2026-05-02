import AIProxy
import Foundation

public enum KeepTalkingPrimitiveActionKind: String, Codable, Sendable,
    Hashable, CaseIterable
{
    case openURLInBrowser = "open-url-in-browser"
    case addToReadingList = "add-to-reading-list"
    case askForFile = "ask-for-file"
    case getCurrentlyPlayingMusic = "get-currently-playing-music"
    case runMacOSShortcut = "run-macos-shortcut"
    /// Prompts the action host's user to create a new action and grant it to the caller.
    case createAction = "create-action"
    /// Access the user's calendar with read (list events) and write (add event) operations.
    /// Operations are selected by the tool's `operation` argument; per-operation
    /// calendar scope lives on `KeepTalkingPrimitiveBundle.scope` keyed by
    /// `"read"` / `"write"` (each value is a list of calendar titles). The grant
    /// further narrows which keys the caller may invoke via
    /// `KeepTalkingGrantPermission.primitive(allowedScopeKeys:)`.
    case accessCalendar = "access-calendar"
}

public struct KeepTalkingPrimitiveBundle: KeepTalkingActionBundle, Equatable {
    public var id: UUID
    public var name: String
    public var indexDescription: String
    public var action: KeepTalkingPrimitiveActionKind
    /// The name of the macOS Shortcut to run. Only used when `action == .runMacOSShortcut`.
    public var shortcutName: String?
    /// Generic scope bag — the set of constraints the action host applies before
    /// executing this primitive (parallels `KeepTalkingFilesystemBundle.rootPath`
    /// and the per-tool scope on MCP servers). The keys and value shapes are
    /// defined per `KeepTalkingPrimitiveActionKind`; each handler is responsible
    /// for documenting the scope keys it understands via its `scopeSchema` and
    /// for enforcing them at call time. `nil` or empty means no scoping.
    ///
    /// Example (calendar): `["read": ["Work", "Personal"], "write": ["Personal"]]`.
    public var scope: [String: [String]]?
    /// When true, remote calls use the blocking-authorisation continuation model
    /// (the remote user must interactively respond before the action returns).
    public var blockingAuthorisation: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        indexDescription: String,
        action: KeepTalkingPrimitiveActionKind,
        shortcutName: String? = nil,
        scope: [String: [String]]? = nil,
        blockingAuthorisation: Bool = false
    ) {
        self.id = id
        self.name = name
        self.indexDescription = indexDescription
        self.action = action
        self.shortcutName = shortcutName
        self.scope = scope
        self.blockingAuthorisation = blockingAuthorisation
    }

    public static let availablePrimitiveActions: [KeepTalkingPrimitiveBundle] = [
        KeepTalkingPrimitiveBundle(
            name: "open-url-in-browser",
            indexDescription:
                "Open a URL with the system browser on the action host.",
            action: .openURLInBrowser
        ),
        KeepTalkingPrimitiveBundle(
            name: "add-to-reading-list",
            indexDescription:
                "Add a URL to the reading list on the action host.",
            action: .addToReadingList
        ),
        KeepTalkingPrimitiveBundle(
            name: "ask-for-file",
            indexDescription:
                "Prompt for a file source on the action host and return selected file metadata.",
            action: .askForFile
        ),
        KeepTalkingPrimitiveBundle(
            name: "get-or-play-music",
            indexDescription:
                "Get metadata about currently playing music on the action host, or play an Apple Music song by URL or store ID.",
            action: .getCurrentlyPlayingMusic
        ),
        KeepTalkingPrimitiveBundle(
            name: "create-action",
            indexDescription:
                "Prompts the user to create a new action and grant it to the caller's context.",
            action: .createAction,
            blockingAuthorisation: true
        ),
        KeepTalkingPrimitiveBundle(
            name: "access-calendar",
            indexDescription:
                "Read (list events in a date range) and write (add events) on the user's calendars on the action host.",
            action: .accessCalendar
        ),
    ]

    public func assigningNewID() -> KeepTalkingPrimitiveBundle {
        var copy = self
        copy.id = UUID()
        return copy
    }
}

extension KeepTalkingPrimitiveActionKind {
    /// JSON-schema fragments describing the scope keys this action kind
    /// accepts on `KeepTalkingPrimitiveBundle.scope`. Empty means this kind
    /// does not accept scoping. Each value is a JSON-schema fragment (an
    /// AIProxyJSONValue object) for that scope key. The agent is expected to
    /// honor these shapes when proposing a `scope` argument to the
    /// `kt_create_primitive` tool, and host-side handlers are expected to
    /// validate against them at execution time.
    public var scopeSchema: [String: AIProxyJSONValue] {
        switch self {
            case .accessCalendar:
                return [
                    "read": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Calendar titles this action may list events from. Empty/omitted means no read scoping."
                        ),
                    ]),
                    "write": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Calendar titles this action may add events to. Empty/omitted means no write scoping."
                        ),
                    ]),
                ]
            case .openURLInBrowser, .addToReadingList, .askForFile,
                .getCurrentlyPlayingMusic, .runMacOSShortcut, .createAction:
                return [:]
        }
    }
}

public struct KeepTalkingPrimitiveActionResponse: Sendable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

public struct KeepTalkingPrimitiveRegistry: Sendable {
    public let toolParameters: @Sendable (KeepTalkingPrimitiveActionKind) -> [String: AIProxyJSONValue]
    /// Executes a primitive call. `allowedScopeKeys` is the resolved per-grant
    /// scope-key allowlist (`nil` = no narrowing beyond the bundle's own scope).
    public let callAction:
        @Sendable (KeepTalkingPrimitiveBundle, KeepTalkingActionCall, _ allowedScopeKeys: [String]?) async throws ->
            KeepTalkingPrimitiveActionResponse

    public init(
        toolParameters: @escaping @Sendable (KeepTalkingPrimitiveActionKind) -> [String: AIProxyJSONValue],
        callAction:
            @escaping @Sendable (
                KeepTalkingPrimitiveBundle,
                KeepTalkingActionCall,
                _ allowedScopeKeys: [String]?
            ) async throws -> KeepTalkingPrimitiveActionResponse
    ) {
        self.toolParameters = toolParameters
        self.callAction = callAction
    }
}
