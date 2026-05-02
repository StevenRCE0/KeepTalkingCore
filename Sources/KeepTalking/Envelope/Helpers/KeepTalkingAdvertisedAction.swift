//
//  KeepTalkingAdvertisedAction.swift
//  KeepTalking
//
//  Created by 砚渤 on 29/03/2026.
//

import Foundation

/// Live runtime availability of an advertised action at the broadcasting node.
///
/// This supersedes the old boolean `disabled` flag — a user-disabled action is
/// `.disabled` here. Receivers should drive UI from `availability`.
public enum KeepTalkingAdvertisedActionAvailability: Codable, Sendable, Equatable {
    /// Owner has the action ready: registered, healthy, and (for MCP) connected.
    case available
    /// User has explicitly disabled the action at the owner node.
    case disabled
    /// MCP server is mid-handshake. Receivers may briefly retry.
    case connecting
    /// Runtime is failing — typically a faulty MCP server. `reason` is a
    /// human-readable summary suitable for surfacing in the recipient UI.
    case failed(reason: String)
    /// Action type has no runtime health concept (skill/primitive/filesystem
    /// /semanticRetrieval). The action is considered live whenever the owner
    /// node is reachable.
    case notApplicable

    public var isUsable: Bool {
        switch self {
            case .available, .notApplicable, .connecting:
                return true
            case .disabled, .failed:
                return false
        }
    }
}

public struct KeepTalkingAdvertisedAction: Codable, Sendable {
    public enum PayloadSummary: Codable, Sendable {
        case mcpBundle(name: String, indexDescription: String)
        case skill(name: String, indexDescription: String)
        case semanticRetrieval(name: String, indexDescription: String)
        case primitive(
            name: String,
            indexDescription: String,
            action: KeepTalkingPrimitiveActionKind
        )
        case filesystem(name: String, indexDescription: String)
    }

    public let actionID: UUID
    public let ownerNodeID: UUID?
    public let descriptor: KeepTalkingActionDescriptor?
    public let payloadSummary: PayloadSummary
    public let remoteAuthorisable: Bool
    public let blockingAuthorisation: Bool
    /// Live runtime state — connectivity for MCP, `.notApplicable` otherwise.
    /// `.disabled` takes the place of the old boolean `disabled` flag.
    public let availability: KeepTalkingAdvertisedActionAvailability
    /// For MCP-backed actions: tool names currently exposed by the live server,
    /// already filtered by the recipient's per-grant tool allowlist. `nil` if
    /// the owner has no live information yet (e.g. server not connected).
    public let tools: [String]?
    public let createdAt: Date?
    public let lastUsed: Date?

    public init(
        actionID: UUID,
        ownerNodeID: UUID?,
        descriptor: KeepTalkingActionDescriptor?,
        payloadSummary: PayloadSummary,
        remoteAuthorisable: Bool,
        blockingAuthorisation: Bool,
        availability: KeepTalkingAdvertisedActionAvailability,
        tools: [String]? = nil,
        createdAt: Date? = nil,
        lastUsed: Date? = nil
    ) {
        self.actionID = actionID
        self.ownerNodeID = ownerNodeID
        self.descriptor = descriptor
        self.payloadSummary = payloadSummary
        self.remoteAuthorisable = remoteAuthorisable
        self.blockingAuthorisation = blockingAuthorisation
        self.availability = availability
        self.tools = tools
        self.createdAt = createdAt
        self.lastUsed = lastUsed
    }
}
