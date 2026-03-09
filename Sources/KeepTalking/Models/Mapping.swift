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
}

public final class KeepTalkingMapping: Model, @unchecked Sendable {
    public static let schema = "kt_mappings"

    @ID(key: .id)
    public var id: UUID?

    @OptionalParent(key: "node")
    public var node: KeepTalkingNode?

    @OptionalParent(key: "context")
    public var context: KeepTalkingContext?

    @Field(key: "kind")
    public var kind: KeepTalkingMappingKind

    @OptionalField(key: "namespace")
    public var namespace: String?

    @Field(key: "value")
    public var value: String

    @Field(key: "normalized_value")
    public var normalizedValue: String

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
        deletedAt: Date? = nil
    ) {
        self.id = id
        switch target {
            case .node(let node):
                self.$node.id = node
            case .context(let context):
                self.$context.id = context
        }
        self.kind = kind
        self.namespace = Self.normalizeOptional(namespace)
        self.value = Self.normalizeStoredValue(value)
        self.normalizedValue = Self.normalizeLookupValue(value)
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
}
