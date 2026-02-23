import FluentKit
import Foundation

public final class KeepTalkingOperatorContext: Model, @unchecked Sendable {
    public static let schema = "kt_operator_context"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "operator")
    public var `operator`: KeepTalkingNode

    @Parent(key: "context")
    public var context: KeepTalkingContext

    public init() {}

    public init(
        id: UUID? = UUID(),
        `operator`: KeepTalkingNode,
        context: KeepTalkingContext
    ) {
        self.id = id
        self.operator = `operator`
        self.context = context
    }
}

public final class KeepTalkingContext: Model, @unchecked Sendable {
    public static let schema = "kt_contexts"

    @ID(key: .id)
    public var id: UUID?

    @Siblings(
        through: KeepTalkingOperatorContext.self,
        from: \.$context,
        to: \.$operator
    )
    public var operators: [KeepTalkingNode]

    @Field(key: "updated_at")
    public var updatedAt: Date

    @Children(for: \.$context)
    public var messages: [KeepTalkingContextMessage]

    public init() {
        self.updatedAt = Date()
    }

    public init(
        id: UUID = UUID(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.updatedAt = updatedAt
    }
}

public typealias KeepTalkingConversationContext = KeepTalkingContext
