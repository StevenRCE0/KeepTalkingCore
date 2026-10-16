import Foundation

public struct KeepTalkingPlatform: Codable, Hashable, Equatable, Sendable {
    public let rawValue: String

    /// iOS, macOS and visionOS(?)
    public static let apple = Self(rawValue: "apple")
    /// The GTK host
    /// TODO: Add detection
    public static let gtk = Self(rawValue: "gtk")

    #if canImport(Darwin)
    public static let current = apple
    #endif
}
