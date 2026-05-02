import Foundation

/// Per-grant permission, stored as a single JSON column on the grant relation row.
///
/// One case per grantable action kind. Each case carries the *capability
/// selector* the grant narrows; the *scope values* (filesystem `rootPath`,
/// per-key calendar names, etc.) live host-side on the action's bundle.
///
/// - `.filesystem`: R/W/X bitmask scoping access to filesystem operations.
/// - `.mcp`: explicit tool allowlist; `nil` tools means all tools are permitted.
/// - `.primitive`: which scope keys from the bundle's `scopeSchema` are exposed
///   to the caller; `nil` means all keys, `[]` means none.
public enum KeepTalkingGrantPermission: Codable, Sendable, Hashable {
    case filesystem(KeepTalkingActionPermissionMask)
    case mcp(allowedTools: [String]?)
    case primitive(allowedScopeKeys: [String]?)

    /// True when this permission imposes no narrowing on its axis. Callers
    /// store `nil` rather than a permission row in this case (the unified
    /// resolver treats a missing row as unrestricted on the kind's axis).
    public var isUnrestricted: Bool {
        switch self {
            case .filesystem(let mask): return mask == .all
            case .mcp(let tools): return tools == nil
            case .primitive(let keys): return keys == nil
        }
    }
}

/// R/W/X bitmask for **filesystem** action grants.
///
/// Stored inside `KeepTalkingGrantPermission.filesystem` on the grant relation row.
/// Each bit maps to a group of filesystem operations:
/// `.read` → ls, read-file, grep, stat; `.write` → write-file; `.execute` → reserved.
public struct KeepTalkingActionPermissionMask: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

extension KeepTalkingActionPermissionMask: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UInt32.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Grants access to read-only operations (ls, read-file, grep, stat).
    public static let read = Self(rawValue: 1 << 0)
    /// Grants access to write/mutate operations (write-file, delete).
    public static let write = Self(rawValue: 1 << 1)
    /// Grants access to execute operations (shell commands, scripts).
    public static let execute = Self(rawValue: 1 << 2)

    /// Convenience: all three capabilities enabled.
    public static let all: Self = [.read, .write, .execute]
}
