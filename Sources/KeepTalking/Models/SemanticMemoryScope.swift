import Foundation

public struct KeepTalkingSemanticMemoryScope: Identifiable, Sendable, Equatable {
    public enum Target: Hashable, Sendable {
        case context(UUID)
        case thread(UUID)
    }

    public struct Tag: Hashable, Sendable {
        public let namespace: String?
        public let value: String
        public let normalizedValue: String
        public let colorHex: String?

        public init(
            namespace: String?,
            value: String,
            normalizedValue: String,
            colorHex: String?
        ) {
            self.namespace = namespace
            self.value = value
            self.normalizedValue = normalizedValue
            self.colorHex = colorHex
        }

        public var title: String {
            namespace.map { "\($0):\(value)" } ?? value
        }
    }

    public let target: Target
    public let contextID: UUID
    public let threadIDs: [UUID]
    public let matchingTags: [Tag]

    public var id: Target { target }

    public init(
        target: Target,
        contextID: UUID,
        threadIDs: [UUID],
        matchingTags: [Tag]
    ) {
        self.target = target
        self.contextID = contextID
        self.threadIDs = threadIDs
        self.matchingTags = matchingTags
    }
}
