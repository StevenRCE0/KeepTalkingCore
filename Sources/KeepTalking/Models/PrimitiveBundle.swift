import AIProxy
import Foundation

public enum KeepTalkingPrimitiveActionKind: String, Codable, Sendable,
    Hashable, CaseIterable
{
    case openWithURL = "open-url-in-browser"
    case addToReadingList = "add-to-reading-list"
    case askForFile = "ask-for-file"
    case getCurrentlyPlayingMusic = "get-currently-playing-music"
    case runMacOSShortcut = "run-macos-shortcut"
    case accessCalendar = "access-calendar"
    case addToReminders = "add-to-reminders"
    case composeEmail = "compose-email"
}

public struct KeepTalkingPrimitiveBundle: KeepTalkingActionBundle, Equatable {
    public var id: UUID
    public var name: String
    public var indexDescription: String
    public var action: KeepTalkingPrimitiveActionKind
    public var shortcutName: String?
    public var scope: [String: [String]]?
    public var blockingAuthorisation: Bool

    public init(
        id: UUID = UUID.v7(),
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
            name: "open-with-url",
            indexDescription:
                "Open a URL via the system API — websites open in the browser, deep-links open native apps directly. Use for: navigate or search on Maps, get directions, call or FaceTime someone, compose a message, search Apple Music or open radio, search the App Store, open Weather, Calendar, Voice Memos, Books, Apple News, TV, or HomeKit.",
            action: .openWithURL
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
            name: "access-calendar",
            indexDescription:
                "Read (list events in a date range) and write (add events) on the user's calendars on the action host. Callers granted only availability see busy times, not event details.",
            action: .accessCalendar
        ),
        KeepTalkingPrimitiveBundle(
            name: "add-to-reminders",
            indexDescription:
                "Read (list reminders) and write (add reminders with title, optional due date, notes, priority) on the user's Reminders lists on the action host.",
            action: .addToReminders
        ),
        KeepTalkingPrimitiveBundle(
            name: "compose-email",
            indexDescription:
                "Open a pre-filled email draft (recipients, subject, body, optional file attachments passed as input_handles) on the action host for the user to review and send. Never sends by itself.",
            action: .composeEmail
        ),
    ]

    public func assigningNewID() -> KeepTalkingPrimitiveBundle {
        var copy = self
        copy.id = UUID.v7()
        return copy
    }
}

extension KeepTalkingPrimitiveActionKind {
    public var scopeSchema: [String: AIProxyJSONValue] {
        switch self {
            case .accessCalendar:
                return [
                    "read": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Calendar titles this action may list events from. Empty/omitted disables reading entirely — listing events becomes unavailable (it does not mean \"all calendars\")."
                        ),
                    ]),
                    "write": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Calendar titles this action may add events to. Empty/omitted disables writing entirely — creating events becomes unavailable (it does not mean \"all calendars\"). Every event names its target calendar; there is no default or system fallback."
                        ),
                    ]),
                    "availability": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Calendar titles shared as availability only: events appear as merged, anonymous busy blocks — times only, no titles, locations, notes or calendar names. A calendar is in `read` or here, never both. Empty/omitted means no availability view."
                        ),
                        Self.opposesKeyword: .array([.string("read")]),
                    ]),
                ]
            case .addToReminders:
                return [
                    "read": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Reminders list titles this action may list reminders from. Empty/omitted disables reading entirely — listing reminders becomes unavailable (it does not mean \"all lists\")."
                        ),
                    ]),
                    "lists": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Reminders list titles this action may add reminders to. Empty/omitted disables adding entirely — adding reminders becomes unavailable (it does not mean \"all lists\"). Every reminder names its target list; there is no default or system fallback."
                        ),
                    ]),
                ]
            case .openWithURL, .addToReadingList, .askForFile,
                .getCurrentlyPlayingMusic, .runMacOSShortcut, .composeEmail:
                return [:]
        }
    }
}

extension KeepTalkingPrimitiveActionKind {
    /// The schema keyword naming the scope keys a key never shares an item
    /// with. On a conflict the declaring key keeps the item.
    public static let opposesKeyword = "x-opposes"

    public func scopeKeys(opposing key: String) -> [String] {
        var opposing = declaredOpposition(of: key)
        for other in scopeSchema.keys where declaredOpposition(of: other).contains(key) {
            if !opposing.contains(other) { opposing.append(other) }
        }
        return opposing.sorted()
    }

    public func resolvingOpposingScopes(_ scope: [String: [String]]) -> [String: [String]] {
        var resolved = scope
        for key in scopeSchema.keys.sorted() {
            guard let claimed = scope[key].map(Set.init) else { continue }
            for opposed in declaredOpposition(of: key) {
                let kept = resolved[opposed]?.filter { !claimed.contains($0) } ?? []
                resolved[opposed] = kept.isEmpty ? nil : kept
            }
        }
        return resolved
    }

    private func declaredOpposition(of key: String) -> [String] {
        guard case .object(let field)? = scopeSchema[key],
            case .array(let names)? = field[Self.opposesKeyword]
        else { return [] }
        return names.compactMap { if case .string(let name) = $0 { name } else { nil } }
    }
}

extension KeepTalkingPrimitiveActionKind {
    public var inputFileObjects: [KeepTalkingActionObject] {
        switch self {
            case .composeEmail:
                return [
                    KeepTalkingActionObject(
                        name: "attachments",
                        description:
                            "Optional files to attach to the draft. Pass each file's handle in input_handles.",
                        resource: .filePaths([]),
                        direction: .input
                    )
                ]
            case .openWithURL, .addToReadingList, .askForFile,
                .getCurrentlyPlayingMusic, .runMacOSShortcut, .accessCalendar,
                .addToReminders:
                return []
        }
    }
}

public struct KeepTalkingPrimitiveActionResponse: Sendable {
    public let text: String
    public let isError: Bool
    public let outputFiles: [KeepTalkingLocalAttachmentInput]

    public init(
        text: String,
        isError: Bool = false,
        outputFiles: [KeepTalkingLocalAttachmentInput] = []
    ) {
        self.text = text
        self.isError = isError
        self.outputFiles = outputFiles
    }
}

public struct KeepTalkingPrimitiveRegistry: Sendable {
    public let toolParameters: @Sendable (KeepTalkingPrimitiveActionKind) -> [String: AIProxyJSONValue]
    /// Executes a primitive call. `allowedScopeKeys` is the resolved per-grant
    /// scope-key allowlist (`nil` = no narrowing beyond the bundle's own scope).
    /// `manifest` is the run's KTRM: the resources the call named in
    /// `inputHandles`, readable for the duration of the call only. `nil` unless
    /// the kind declares input files and the call named some.
    public let callAction:
        @Sendable (
            KeepTalkingPrimitiveBundle,
            KeepTalkingActionCall,
            _ allowedScopeKeys: [String]?,
            _ manifest: KTResourceManifest?
        ) async throws -> KeepTalkingPrimitiveActionResponse

    public init(
        toolParameters: @escaping @Sendable (KeepTalkingPrimitiveActionKind) -> [String: AIProxyJSONValue],
        callAction:
            @escaping @Sendable (
                KeepTalkingPrimitiveBundle,
                KeepTalkingActionCall,
                _ allowedScopeKeys: [String]?,
                _ manifest: KTResourceManifest?
            ) async throws -> KeepTalkingPrimitiveActionResponse
    ) {
        self.toolParameters = toolParameters
        self.callAction = callAction
    }
}
