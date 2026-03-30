//
//  KeepTalkingAdvertisedAction.swift
//  KeepTalking
//
//  Created by 砚渤 on 29/03/2026.
//

import Foundation

public struct KeepTalkingAdvertisedAction: Codable, Sendable {
    public enum PayloadSummary: Codable, Sendable {
        case mcpBundle(name: String, indexDescription: String)
        case skill(name: String, indexDescription: String)
        case primitive(
            name: String,
            indexDescription: String,
            action: KeepTalkingPrimitiveActionKind
        )
    }

    public let actionID: UUID
    public let ownerNodeID: UUID?
    public let descriptor: KeepTalkingActionDescriptor?
    public let payloadSummary: PayloadSummary
    public let remoteAuthorisable: Bool
    public let blockingAuthorisation: Bool
    public let disabled: Bool
    public let createdAt: Date?
    public let lastUsed: Date?

    public init(
        actionID: UUID,
        ownerNodeID: UUID?,
        descriptor: KeepTalkingActionDescriptor?,
        payloadSummary: PayloadSummary,
        remoteAuthorisable: Bool,
        blockingAuthorisation: Bool,
        disabled: Bool = false,
        createdAt: Date? = nil,
        lastUsed: Date? = nil
    ) {
        self.actionID = actionID
        self.ownerNodeID = ownerNodeID
        self.descriptor = descriptor
        self.payloadSummary = payloadSummary
        self.remoteAuthorisable = remoteAuthorisable
        self.blockingAuthorisation = blockingAuthorisation
        self.disabled = disabled
        self.createdAt = createdAt
        self.lastUsed = lastUsed
    }
}
