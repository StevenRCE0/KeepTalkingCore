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

// MARK: - Agent Turn Continuation

/// Response sent from node B back to node A when a remote user fulfils
/// (or rejects) a suspended agent turn continuation.
public struct KeepTalkingAgentTurnContinuationResponse: Codable, Sendable, KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .encryptedAgentTurnContinuationResponse }
    public var participantNodeIDs: [UUID] { [responderNodeID, originNodeID] }
    public var targetPeerNodeID: UUID? { originNodeID }
    public var transportContextID: UUID? { contextID }
    public var continuationMessageID: UUID
    public var agentTurnID: UUID
    public var contextID: UUID
    public var responderNodeID: UUID
    public var originNodeID: UUID
    public var state: KeepTalkingContextMessage.AgentTurnContinuationState
    /// Asym-encrypted payload containing the response data (tool result, file refs, etc.)
    public var encryptedPayload: Data
    public var plainTextHint: String?

    public init(
        continuationMessageID: UUID,
        agentTurnID: UUID,
        contextID: UUID,
        responderNodeID: UUID,
        originNodeID: UUID,
        state: KeepTalkingContextMessage.AgentTurnContinuationState,
        encryptedPayload: Data,
        plainTextHint: String? = nil
    ) {
        self.continuationMessageID = continuationMessageID
        self.agentTurnID = agentTurnID
        self.contextID = contextID
        self.responderNodeID = responderNodeID
        self.originNodeID = originNodeID
        self.state = state
        self.encryptedPayload = encryptedPayload
        self.plainTextHint = plainTextHint
    }
}

public enum KeepTalkingRequestAckKind: String, Codable, Sendable {
    case actionCall
}

public enum KeepTalkingRequestAckState: String, Codable, Sendable {
    case received
    case accepted
    case rejected
}

public struct KeepTalkingRequestAck: Codable, Sendable {
    public var requestID: UUID
    public var contextID: UUID
    public var callerNodeID: UUID
    public var targetNodeID: UUID
    public var kind: KeepTalkingRequestAckKind
    public var state: KeepTalkingRequestAckState
    public var actionID: UUID?
    public var message: String?

    public init(
        requestID: UUID,
        contextID: UUID,
        callerNodeID: UUID,
        targetNodeID: UUID,
        kind: KeepTalkingRequestAckKind,
        state: KeepTalkingRequestAckState,
        actionID: UUID? = nil,
        message: String? = nil
    ) {
        self.requestID = requestID
        self.contextID = contextID
        self.callerNodeID = callerNodeID
        self.targetNodeID = targetNodeID
        self.kind = kind
        self.state = state
        self.actionID = actionID
        self.message = message
    }
}

public enum KeepTalkingActionCatalogQueryKind: String, Codable, Sendable {
    case mcpTools
    case skillMetadata
    case skillFile
    case filesystemTools
}

public struct KeepTalkingActionCatalogQuery: Codable, Sendable {
    public var actionID: UUID
    public var kind: KeepTalkingActionCatalogQueryKind
    public var arguments: [String: Value]?

    public init(
        actionID: UUID,
        kind: KeepTalkingActionCatalogQueryKind,
        arguments: [String: Value]? = nil
    ) {
        self.actionID = actionID
        self.kind = kind
        self.arguments = arguments
    }
}

public struct KeepTalkingActionCatalogRequest: Codable, Sendable {
    public var id: UUID
    public var contextID: UUID
    public var callerNodeID: UUID
    public var targetNodeID: UUID
    public var queries: [KeepTalkingActionCatalogQuery]

    public init(
        id: UUID = UUID(),
        contextID: UUID,
        callerNodeID: UUID,
        targetNodeID: UUID,
        queries: [KeepTalkingActionCatalogQuery]
    ) {
        self.id = id
        self.contextID = contextID
        self.callerNodeID = callerNodeID
        self.targetNodeID = targetNodeID
        self.queries = queries
    }
}

public struct KeepTalkingActionCatalogMCPTool: Codable, Sendable {
    public var name: String
    public var description: String?
    public var inputSchema: Value?

    public init(
        name: String,
        description: String? = nil,
        inputSchema: Value? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct KeepTalkingActionCatalogSkillMetadata: Codable, Sendable {
    public var name: String
    public var directoryPath: String
    public var manifestPath: String
    public var manifestMetadata: [String: String]
    public var referencesFiles: [String]
    public var scripts: [String]
    public var assets: [String]
    public var manifestPreview: String

    public init(
        name: String,
        directoryPath: String,
        manifestPath: String,
        manifestMetadata: [String: String] = [:],
        referencesFiles: [String] = [],
        scripts: [String] = [],
        assets: [String] = [],
        manifestPreview: String = ""
    ) {
        self.name = name
        self.directoryPath = directoryPath
        self.manifestPath = manifestPath
        self.manifestMetadata = manifestMetadata
        self.referencesFiles = referencesFiles
        self.scripts = scripts
        self.assets = assets
        self.manifestPreview = manifestPreview
    }
}

public struct KeepTalkingActionCatalogSkillFile: Codable, Sendable {
    public var path: String
    public var content: String
    public var maxCharacters: Int
    public var truncated: Bool

    public init(
        path: String,
        content: String,
        maxCharacters: Int,
        truncated: Bool
    ) {
        self.path = path
        self.content = content
        self.maxCharacters = maxCharacters
        self.truncated = truncated
    }
}

public struct KeepTalkingActionCatalogItemResult: Codable, Sendable {
    public var actionID: UUID
    public var kind: KeepTalkingActionCatalogQueryKind
    public var mcpTools: [KeepTalkingActionCatalogMCPTool]
    public var skillMetadata: KeepTalkingActionCatalogSkillMetadata?
    public var skillFile: KeepTalkingActionCatalogSkillFile?
    public var filesystemTools: [KeepTalkingFilesystemTool]
    public var isError: Bool
    public var errorMessage: String?

    public init(
        actionID: UUID,
        kind: KeepTalkingActionCatalogQueryKind,
        mcpTools: [KeepTalkingActionCatalogMCPTool] = [],
        skillMetadata: KeepTalkingActionCatalogSkillMetadata? = nil,
        skillFile: KeepTalkingActionCatalogSkillFile? = nil,
        filesystemTools: [KeepTalkingFilesystemTool] = [],
        isError: Bool = false,
        errorMessage: String? = nil
    ) {
        self.actionID = actionID
        self.kind = kind
        self.mcpTools = mcpTools
        self.skillMetadata = skillMetadata
        self.skillFile = skillFile
        self.filesystemTools = filesystemTools
        self.isError = isError
        self.errorMessage = errorMessage
    }
}

public struct KeepTalkingActionCatalogResult: Codable, Sendable {
    public var requestID: UUID
    public var contextID: UUID
    public var callerNodeID: UUID
    public var targetNodeID: UUID
    public var items: [KeepTalkingActionCatalogItemResult]
    public var isError: Bool
    public var errorMessage: String?

    public init(
        requestID: UUID,
        contextID: UUID,
        callerNodeID: UUID,
        targetNodeID: UUID,
        items: [KeepTalkingActionCatalogItemResult] = [],
        isError: Bool = false,
        errorMessage: String? = nil
    ) {
        self.requestID = requestID
        self.contextID = contextID
        self.callerNodeID = callerNodeID
        self.targetNodeID = targetNodeID
        self.items = items
        self.isError = isError
        self.errorMessage = errorMessage
    }
}
