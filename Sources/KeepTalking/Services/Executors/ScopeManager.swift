import Foundation

/// Request to create a new scoped action, either locally or on a remote node.
public struct KTActionCreationRequest: Codable, Sendable {
    public var id: UUID
    public var contextID: UUID
    public var requesterNodeID: UUID
    public var targetNodeID: UUID
    public var descriptor: KeepTalkingActionDescriptor
    public var duration: KeepTalkingActionGrantDuration
    public var reason: String

    public init(
        id: UUID = UUID(),
        contextID: UUID,
        requesterNodeID: UUID,
        targetNodeID: UUID,
        descriptor: KeepTalkingActionDescriptor,
        duration: KeepTalkingActionGrantDuration,
        reason: String
    ) {
        self.id = id
        self.contextID = contextID
        self.requesterNodeID = requesterNodeID
        self.targetNodeID = targetNodeID
        self.descriptor = descriptor
        self.duration = duration
        self.reason = reason
    }
}

/// Result of a scoped action creation request.
public struct KTActionCreationResult: Codable, Sendable {
    public var requestID: UUID
    public var created: Bool
    public var actionID: UUID?
    public var grant: KeepTalkingActionGrant?
    public var message: String?

    public init(
        requestID: UUID,
        created: Bool,
        actionID: UUID? = nil,
        grant: KeepTalkingActionGrant? = nil,
        message: String? = nil
    ) {
        self.requestID = requestID
        self.created = created
        self.actionID = actionID
        self.grant = grant
        self.message = message
    }
}

#if os(macOS)
/// Central actor managing sandbox scope grants and policy resolution.
///
/// The ScopeManager sits between action executors and the platform sandbox backend.
/// It tracks active grants, surfaces approval requests to the user via a callback,
/// and resolves the final `KTSandboxPolicy` for any action at execution time.
public actor ScopeManager {

    /// Callback surfaced to the app layer for user approval of action creation requests.
    public typealias ActionCreationApprovalHandler = @Sendable (
        KTActionCreationRequest
    ) async -> (approved: Bool, duration: KeepTalkingActionGrantDuration)

    private let sandbox: any ProcessSandboxing
    private var activeGrants: [UUID: KeepTalkingActionGrant] = [:]
    private var sessionGrantIDs: Set<UUID> = []
    private var approvalHandler: ActionCreationApprovalHandler?

    public init(sandbox: any ProcessSandboxing) {
        self.sandbox = sandbox
    }

    public func setApprovalHandler(_ handler: ActionCreationApprovalHandler?) {
        self.approvalHandler = handler
    }

    // MARK: - Grant management

    public func addGrant(_ grant: KeepTalkingActionGrant) {
        activeGrants[grant.id] = grant
        if grant.duration == .session {
            sessionGrantIDs.insert(grant.id)
        }
    }

    public func removeGrant(id: UUID) {
        activeGrants.removeValue(forKey: id)
        sessionGrantIDs.remove(id)
    }

    public func clearSessionGrants() {
        for id in sessionGrantIDs {
            activeGrants.removeValue(forKey: id)
        }
        sessionGrantIDs.removeAll()
    }

    public func grants() -> [KeepTalkingActionGrant] {
        Array(activeGrants.values)
    }

    public func grants(forActionID actionID: UUID) -> [KeepTalkingActionGrant] {
        activeGrants.values.filter { grant in
            if case .command(let cmds) = grant.descriptor.subject?.resource {
                return cmds.first?.first == actionID.uuidString.lowercased()
            }
            return false
        }
    }

    // MARK: - Action creation requests

    public func requestActionCreation(
        _ request: KTActionCreationRequest
    ) async -> KeepTalkingActionGrant? {
        guard let approvalHandler else { return nil }
        let (approved, duration) = await approvalHandler(request)
        guard approved else { return nil }
        let grant = KeepTalkingActionGrant(
            descriptor: request.descriptor,
            duration: duration,
            grantedByNodeID: request.targetNodeID
        )
        addGrant(grant)
        return grant
    }

    // MARK: - Policy resolution

    public func resolvedPolicy(
        for action: KeepTalkingAction
    ) throws -> KTSandboxPolicy {
        let grants = Array(activeGrants.values)
        return try ScopeResolver.resolvedPolicy(
            for: action,
            additionalGrants: grants,
            sandbox: sandbox
        )
    }
}
#endif
