import FluentKit
import Foundation

/// Describes the concrete resource an action can operate on.
public enum KeepTalkingActionResource: Codable, Sendable {
    case urls([URL])
    case filePaths([URL])
    case command([[String]])
}

/// Wraps an action resource with human-readable context for catalog displays.
public struct KeepTalkingActionResourceWithDescription: Codable, Sendable {
    public var description: String
    public var resource: KeepTalkingActionResource
}

/// Describes the verb portion of an action descriptor.
public struct KeepTalkingActionWithDescription: Codable, Sendable {
    public var description: String
}

/// Provides subject-action-object metadata used to explain an action to users and AI planners.
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

/// Persisted action model that binds an executable payload to a node.
public final class KeepTalkingAction: Model, @unchecked Sendable {

    public static let schema: String = "kt_actions"

    public enum Payload: Codable, Sendable {
        case mcpBundle(KeepTalkingMCPBundle)
        case skill(KeepTalkingSkillBundle)
        case primitive(KeepTalkingPrimitiveBundle)
        case semanticRetrieval(KeepTalkingSemanticRetrievalBundle)
        case filesystem(KeepTalkingFilesystemBundle)

        public var isSemanticRetrieval: Bool {
            if case .semanticRetrieval = self { return true }
            return false
        }

        public var semanticRetrievalBundle: KeepTalkingSemanticRetrievalBundle? {
            if case .semanticRetrieval(let bundle) = self { return bundle }
            return nil
        }

        public var filesystemBundle: KeepTalkingFilesystemBundle? {
            if case .filesystem(let bundle) = self { return bundle }
            return nil
        }
    }

    public var isSemanticRetrieval: Bool {
        payload.isSemanticRetrieval == true
    }

    public var actionLabel: String {
        if case .mcpBundle(let bundle) = payload {
            return bundle.name
        }
        if case .skill(let bundle) = payload {
            return bundle.name
        }
        if case .primitive(let bundle) = payload {
            return bundle.name
        }
        if case .filesystem(let bundle) = payload {
            return bundle.name
        }

        return id?.uuidString.uppercased() ?? "Unknown Action"
    }

    public var beautifulLabel: String {
        actionLabel
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized(with: .autoupdatingCurrent)
    }

    @ID(key: .id)
    public var id: UUID?

    @OptionalParent(key: "node")
    public var node: KeepTalkingNode?

    @Field(key: "descriptor")
    public var descriptor: KeepTalkingActionDescriptor?

    @Field(key: "payload")
    public var payload: Payload

    @Field(key: "remote_authorisable")
    public var remoteAuthorisable: Bool?

    @Field(key: "blocking_authorisation")
    public var blockingAuthorisation: Bool?

    @OptionalField(key: "disabled")
    public var disabled: Bool?

    /// Locally cached MCP tool names for this action.
    /// Populated when tools are first fetched (registration, edit, or catalog resolution).
    /// Not synced via node-status or grants — remote tool availability is always requested live.
    @OptionalField(key: "cached_mcp_tools")
    public var cachedMCPTools: [String]?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "last_used", on: .none)
    public var lastUsed: Date?

    /// Creates an empty model instance for Fluent.
    public init() {}

    /// Creates a persisted action with its runtime payload and authorization settings.
    ///
    /// - Parameters:
    ///   - id: Stable action identifier.
    ///   - payload: Executable action payload.
    ///   - remoteAuthorisable: Whether a remote node may authorize this action.
    ///   - blockingAuthorisation: Whether execution waits for authorization to complete.
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
