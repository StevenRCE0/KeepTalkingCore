//
//  KeepTalkingActionCall.swift
//  KeepTalking
//
//  Created by 砚渤 on 24/02/2026.
//

import Foundation
import MCP

public struct KeepTalkingActionCall: Codable, Sendable {
    public var action: UUID
    public var arguments: [String: Value]
    public var metadata: Metadata

    public init(
        action: UUID,
        arguments: [String: Value] = [:],
        metadata: Metadata = .init()
    ) {
        self.action = action
        self.arguments = arguments
        self.metadata = metadata
    }
}

public struct KeepTalkingActionCallRequest: Codable, Sendable {
    public var id: UUID
    public var contextID: UUID
    public var callerNodeID: UUID
    public var targetNodeID: UUID
    public var call: KeepTalkingActionCall

    public init(
        id: UUID = UUID(),
        contextID: UUID,
        callerNodeID: UUID,
        targetNodeID: UUID,
        call: KeepTalkingActionCall
    ) {
        self.id = id
        self.contextID = contextID
        self.callerNodeID = callerNodeID
        self.targetNodeID = targetNodeID
        self.call = call
    }
}

public struct KeepTalkingActionCallResult: Codable, Sendable {
    public var requestID: UUID
    public var contextID: UUID
    public var callerNodeID: UUID
    public var targetNodeID: UUID
    public var actionID: UUID
    public var content: [Tool.Content]
    public var isError: Bool
    public var errorMessage: String?

    public init(
        requestID: UUID,
        contextID: UUID,
        callerNodeID: UUID,
        targetNodeID: UUID,
        actionID: UUID,
        content: [Tool.Content] = [],
        isError: Bool = false,
        errorMessage: String? = nil
    ) {
        self.requestID = requestID
        self.contextID = contextID
        self.callerNodeID = callerNodeID
        self.targetNodeID = targetNodeID
        self.actionID = actionID
        self.content = content
        self.isError = isError
        self.errorMessage = errorMessage
    }
}
