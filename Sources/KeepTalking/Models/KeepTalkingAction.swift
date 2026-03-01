import FluentKit
import Foundation

public enum KeepTalkingActionResource: Codable, Sendable {
    case urls([URL])
    case filePaths([URL])
    case command([[String]])
}

public struct KeepTalkingActionResourceWithDescription: Codable, Sendable {
    var description: String
    var resource: KeepTalkingActionResource
}

public struct KeepTalkingActionWithDescription: Codable, Sendable {
    var description: String
}

public struct KeepTalkingActionDescriptor: Codable, Sendable {
    public var subject: KeepTalkingActionResourceWithDescription?
    public var action: KeepTalkingActionWithDescription?
    public var object: KeepTalkingActionResourceWithDescription?
}

public protocol KeepTalkingActionBundle: Identifiable, Codable, Sendable, Hashable {
    var id: UUID { get set }
    var name: String { get set }
    var indexDescription: String { get set }
}

public final class KeepTalkingAction: Model, @unchecked Sendable {

    public static let schema: String = "kt_actions"

    public enum Payload: Codable, Sendable {
        case mcpBundle(KeepTalkingMCPBundle)
        case skill(KeepTalkingSkillBundle)
        case primitive(KeepTalkingPrimitiveBundle)
    }

    @ID(key: .id)
    public var id: UUID?

    @OptionalParent(key: "node")
    public var node: KeepTalkingNode?

    @Field(key: "descriptor")
    public var descriptor: KeepTalkingActionDescriptor?

    @Field(key: "payload")
    public var payload: Payload?

    @Field(key: "remote_authorisable")
    public var remoteAuthorisable: Bool?

    @Field(key: "blocking_authorisation")
    public var blockingAuthorisation: Bool?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "last_used", on: .none)
    public var lastUsed: Date?

    public init() {}

    public init(
        id: UUID = UUID(),
        payload: Payload,
        remoteAuthorisable: Bool,
        blockingAuthorisation: Bool
    ) {
        self.id = id
        self.payload = payload
        self.remoteAuthorisable = remoteAuthorisable
        self.blockingAuthorisation = blockingAuthorisation
    }
}
