import Foundation

public struct KeepTalkingWorkspaceDeltaPayload: Codable, Sendable {
    public let from: UUID
    public let contextID: UUID
    public let schema: String
    public let change: Data
}

extension KeepTalkingWorkspaceDeltaPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .workspaceDelta }
    public var transportContextID: UUID? { contextID }
}

public struct KeepTalkingWorkspaceStagePayload: Codable, Sendable {
    public let from: UUID
    public let contextID: UUID
    public let stage: KeepTalkingWorkspaceStage
}

extension KeepTalkingWorkspaceStagePayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .workspaceStage }
    public var transportContextID: UUID? { contextID }
}

public struct KeepTalkingWorkspaceViewportPayload: Codable, Sendable {
    public let from: UUID
    public let contextID: UUID
    public let schema: String
    public let state: KeepTalkingWorkspaceViewport
}

extension KeepTalkingWorkspaceViewportPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .workspaceViewport }
    public var transportContextID: UUID? { contextID }
}

public struct KeepTalkingWorkspaceCatalogPayload: Codable, Sendable {
    public let from: UUID
    public let contextID: UUID
    public let workspaces: [KeepTalkingContextWorkspaceRecord]
}

extension KeepTalkingWorkspaceCatalogPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .workspaceCatalog }
    public var transportContextID: UUID? { contextID }
}

public struct KeepTalkingWorkspaceResourcesPayload: Codable, Sendable {
    public let from: UUID
    public let contextID: UUID
    public let resources: [KeepTalkingWorkspaceResourceRecord]
}

extension KeepTalkingWorkspaceResourcesPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .workspaceResources }
    public var transportContextID: UUID? { contextID }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    mutating func registerWorkspaceHandlers(for client: KeepTalkingClient) {
        registerReportingApplied(KeepTalkingWorkspaceDeltaPayload.self) { [weak client] payload in
            client?.handleIncomingWorkspaceDelta(payload) ?? false
        }
        registerReportingApplied(KeepTalkingWorkspaceStagePayload.self) { [weak client] payload in
            try await client?.handleIncomingWorkspaceStage(payload) ?? false
        }
        register(KeepTalkingWorkspaceViewportPayload.self) { [weak client] payload in
            client?.handleIncomingWorkspaceViewport(payload)
        }
        registerReportingApplied(KeepTalkingWorkspaceCatalogPayload.self) { [weak client] payload in
            try await client?.handleIncomingWorkspaceCatalog(payload) ?? false
        }
        registerReportingApplied(KeepTalkingWorkspaceResourcesPayload.self) { [weak client] payload in
            try await client?.handleIncomingWorkspaceResources(payload) ?? false
        }
    }
}
