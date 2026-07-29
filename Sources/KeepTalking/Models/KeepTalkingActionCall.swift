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
    /// One-time blobs the caller is streaming to the executor alongside this
    /// call. Used ONLY by the `stage-file` preflight to deliver the bytes being
    /// staged; real tool calls reference staged files by `inputHandles` instead.
    public var inputTransfers: [KeepTalkingOneTimeBlobRef]?
    /// Handles to files the caller previously *preflighted* (staged) onto the
    /// executor via `sendFile`. The executor resolves each to its staged path
    /// and feeds it to the action's input file object. Optional.
    public var inputHandles: [UUID]?
    /// Caller-allocated OUTPUT handles: what the caller expects this call to
    /// produce. The CALLER mints each `id` (so it can track the output and re-feed
    /// it as a later call's input — A→B chaining), picks `persistence` (durable
    /// synced attachment vs private ephemeral OTB), and sets `multiple` (whether the
    /// handle may resolve to 0..N files). The provider binds its produced output(s)
    /// to these instead of minting its own slot ids. Optional; absent ⇒ provider
    /// mints slots from its declared `.output` objects (back-compat).
    public var outputHandles: [KeepTalkingActionOutputHandle]?

    public init(
        action: UUID,
        arguments: [String: Value] = [:],
        metadata: Metadata = .init(),
        inputTransfers: [KeepTalkingOneTimeBlobRef]? = nil,
        inputHandles: [UUID]? = nil,
        outputHandles: [KeepTalkingActionOutputHandle]? = nil
    ) {
        self.action = action
        self.arguments = arguments
        self.metadata = metadata
        self.inputTransfers = inputTransfers
        self.inputHandles = inputHandles
        self.outputHandles = outputHandles
    }
}

/// A caller-allocated OUTPUT the caller expects a call to produce. The caller mints
/// `id` (track + re-feed as a later call's input — A→B chaining), chooses
/// `persistence` (durable synced attachment vs private ephemeral OTB), and sets
/// `multiple` (resolves to 0..N files, not just one). Symmetric to
/// `KeepTalkingActionCall.inputHandles`. Deliberately has NO `isDirectory`: a
/// transferred output is always a file; "many files" is `multiple`, and local
/// directories are sandbox grants, not outputs.
public struct KeepTalkingActionOutputHandle: Codable, Sendable, Equatable {
    /// Where a produced output is delivered.
    public enum Persistence: String, Codable, Sendable {
        /// Durable, broadcast/synced, immutable context attachment.
        case attachment
        /// Private, point-to-point, ephemeral one-time blob (no record, no broadcast).
        case otb
    }
    /// Caller-minted id; the produced output(s) round-trip tagged with it.
    public var id: UUID
    /// Logical role name (e.g. "result"); drives the manifest handle token.
    public var name: String
    /// Delivery family for what this call produces.
    public var persistence: Persistence
    /// Whether this handle may resolve to 0..N files (a collection) rather than one.
    public var multiple: Bool

    public init(
        id: UUID = UUID.v7(),
        name: String,
        persistence: Persistence,
        multiple: Bool = false
    ) {
        self.id = id
        self.name = name
        self.persistence = persistence
        self.multiple = multiple
    }
}

public struct KeepTalkingActionCallRequest: Codable, Sendable {
    public var id: UUID
    public var contextID: UUID
    public var callerNodeID: UUID
    public var targetNodeID: UUID
    public var call: KeepTalkingActionCall

    public init(
        id: UUID = UUID.v7(),
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

public struct KeepTalkingActionCallActivity: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case began
        case ended
    }

    public let requestID: UUID
    public let contextID: UUID
    public let actionID: UUID
    public let callerNodeID: UUID
    public let targetNodeID: UUID
    public let phase: Phase

    public init(
        requestID: UUID,
        contextID: UUID,
        actionID: UUID,
        callerNodeID: UUID,
        targetNodeID: UUID,
        phase: Phase
    ) {
        self.requestID = requestID
        self.contextID = contextID
        self.actionID = actionID
        self.callerNodeID = callerNodeID
        self.targetNodeID = targetNodeID
        self.phase = phase
    }

    init(request: KeepTalkingActionCallRequest, phase: Phase) {
        self.init(
            requestID: request.id,
            contextID: request.contextID,
            actionID: request.call.action,
            callerNodeID: request.callerNodeID,
            targetNodeID: request.targetNodeID,
            phase: phase
        )
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
    /// One-time blobs the executor is streaming back to the caller (e.g. a file
    /// read from the remote host). Each carries the sealed per-transfer key.
    public var outputTransfers: [KeepTalkingOneTimeBlobRef]?
    /// The resources this call PRODUCED, in the unified agent-facing resource
    /// format — summoned durable attachments and/or private OTB outputs. Surfaced
    /// to the orchestrating agent so it can reference them (same vocabulary as the
    /// context-attachment listing).
    public var producedResources: [KTResourceManifest.AgentResource]?

    public init(
        requestID: UUID,
        contextID: UUID,
        callerNodeID: UUID,
        targetNodeID: UUID,
        actionID: UUID,
        content: [Tool.Content] = [],
        isError: Bool = false,
        errorMessage: String? = nil,
        outputTransfers: [KeepTalkingOneTimeBlobRef]? = nil,
        producedResources: [KTResourceManifest.AgentResource]? = nil
    ) {
        self.requestID = requestID
        self.contextID = contextID
        self.callerNodeID = callerNodeID
        self.targetNodeID = targetNodeID
        self.actionID = actionID
        self.content = content
        self.isError = isError
        self.errorMessage = errorMessage
        self.outputTransfers = outputTransfers
        self.producedResources = producedResources
    }
}

// MARK: - Agent Turn Continuation

/// Response sent from node B back to node A when a remote user fulfils
/// (or rejects) a suspended agent turn continuation.
public struct KeepTalkingAgentTurnContinuationResponse: Codable, Sendable, KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .encryptedAgentTurnContinuationResponse }
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
        id: UUID = UUID.v7(),
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
