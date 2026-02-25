import FluentKit
import Foundation

public final class KeepTalkingContextGroupSecret: Model, @unchecked Sendable {
    public static let schema = "kt_context_group_secrets"

    @ID(custom: "context_id", generatedBy: .user)
    public var id: UUID?

    @Field(key: "secret")
    public var secret: Data

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(contextID: UUID, secret: Data) {
        self.id = contextID
        self.secret = secret
    }
}
