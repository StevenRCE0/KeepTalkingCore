import Foundation

public enum KeepTalkingPrimitiveActionKind: String, Codable, Sendable,
    Hashable, CaseIterable
{
    case openURLInBrowser = "open-url-in-browser"
}

public struct KeepTalkingPrimitiveBundle: KeepTalkingActionBundle {
    public var id: UUID
    public var name: String
    public var indexDescription: String
    public var action: KeepTalkingPrimitiveActionKind

    public init(
        id: UUID = UUID(),
        name: String,
        indexDescription: String,
        action: KeepTalkingPrimitiveActionKind
    ) {
        self.id = id
        self.name = name
        self.indexDescription = indexDescription
        self.action = action
    }

    public static let availablePrimitiveActions: [KeepTalkingPrimitiveBundle] = [
        KeepTalkingPrimitiveBundle(
            name: "open-url-in-browser",
            indexDescription:
                "Open a URL with the system browser on the action host.",
            action: .openURLInBrowser
        )
    ]

    public func assigningNewID() -> KeepTalkingPrimitiveBundle {
        var copy = self
        copy.id = UUID()
        return copy
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

public typealias KeepTalkingPrimitiveActionCallback =
    @Sendable (
        _ primitive: KeepTalkingPrimitiveBundle,
        _ call: KeepTalkingActionCall
    ) async throws -> KeepTalkingPrimitiveActionResponse
