import FluentKit
import Foundation

public enum KeepTalkingMappingError: LocalizedError {
    case emptyValue

    public var errorDescription: String? {
        switch self {
            case .emptyValue:
                return "Value must not be empty."
        }
    }
}

public enum KeepTalkingMappingKind: String, Codable, Sendable, CaseIterable {
    case alias
    case tag
}

public enum KeepTalkingMappingTarget: Sendable, Hashable {
    case node(UUID)
    case context(UUID)
    case thread(UUID)

    var id: UUID {
        switch self {
            case .node(let id):
                return id
            case .context(let id):
                return id
            case .thread(let id):
                return id
        }
    }
}

public final class KeepTalkingMapping: Model, @unchecked Sendable {
    public static let schema = "kt_mappings"

    @ID(key: .id)
    public var id: UUID?

    @OptionalParent(key: "node")
    public var node: KeepTalkingNode?

    @OptionalParent(key: "context")
    public var context: KeepTalkingContext?

    @OptionalField(key: "thread")
    public var thread: UUID?

    @Field(key: "kind")
    public var kind: KeepTalkingMappingKind

    @OptionalField(key: "namespace")
    public var namespace: String?

    @Field(key: "value")
    public var value: String

    @Field(key: "normalized_value")
    public var normalizedValue: String

    @OptionalField(key: "color_hex")
    public var colorHex: String?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    @OptionalField(key: "deleted_at")
    public var deletedAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(),
        target: KeepTalkingMappingTarget,
        kind: KeepTalkingMappingKind,
        namespace: String? = nil,
        value: String,
        colorHex: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        switch target {
            case .node(let node):
                self.$node.id = node
            case .context(let context):
                self.$context.id = context
            case .thread(let thread):
                self.thread = thread
        }
        self.kind = kind
        self.namespace = Self.normalizeOptional(namespace)
        self.value = Self.normalizeStoredValue(value)
        self.normalizedValue = Self.normalizeLookupValue(value)
        self.colorHex = Self.normalizeOptional(colorHex)
        self.deletedAt = deletedAt
    }
}

extension KeepTalkingMapping {
    public var target: KeepTalkingMappingTarget? {
        if let node = $node.id {
            return .node(node)
        }
        if let context = $context.id {
            return .context(context)
        }
        if let thread {
            return .thread(thread)
        }
        return nil
    }

    static func normalizeStoredValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeLookupValue(_ value: String) -> String {
        normalizeStoredValue(value).lowercased()
    }

    static func normalizeOptional(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = normalizeStoredValue(value)
        return normalized.isEmpty ? nil : normalized
    }

    static func randomColorHex() -> String {
        let hue = Double.random(in: 0...1)
        let saturation = Double.random(in: 0.45...0.7)
        let brightness = Double.random(in: 0.75...0.9)
        let components = rgb(
            hue: hue,
            saturation: saturation,
            brightness: brightness
        )

        return String(
            format: "#%02X%02X%02X",
            components.red,
            components.green,
            components.blue
        )
    }

    private static func rgb(
        hue: Double,
        saturation: Double,
        brightness: Double
    ) -> (red: Int, green: Int, blue: Int) {
        let h = (hue - floor(hue)) * 6
        let i = Int(floor(h))
        let f = h - Double(i)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))

        let (red, green, blue): (Double, Double, Double)
        switch i % 6 {
            case 0:
                (red, green, blue) = (brightness, t, p)
            case 1:
                (red, green, blue) = (q, brightness, p)
            case 2:
                (red, green, blue) = (p, brightness, t)
            case 3:
                (red, green, blue) = (p, q, brightness)
            case 4:
                (red, green, blue) = (t, p, brightness)
            default:
                (red, green, blue) = (brightness, p, q)
        }

        return (
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}
