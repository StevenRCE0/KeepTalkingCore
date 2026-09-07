import Foundation

/// Which surface issued a grant mutation. Rides the call into the SDK and is
/// stamped on the resulting `KeepTalkingGrantCommit`, so a telemetry consumer
/// can tell a Workbench drop from a plan-driven grant without knowing the UI.
public enum KeepTalkingGrantLane: String, Sendable, Codable, Hashable {
    /// Chat-side panels: the grant popup, the Access sheet, tag management.
    case chat
    /// The Workbench board.
    case workbench
    /// Workspace-plan progression (bind, fulfil, set-up catch-up).
    case plan
    /// Grants applied as part of creating an action.
    case createAction
    /// The mutual create-action grant that follows a trust handshake.
    case trustAutoGrant
    /// The create-action grant a joiner makes to the inviter named by the
    /// ktctx link it redeemed, at join — before any handshake completes.
    case inviteAutoGrant
    /// Anything that did not say — CLI, tests, callers not yet annotated.
    case other
}

/// One committed change to a peer's access, as observed by
/// `KeepTalkingClient.onGrantCommitted`. Deliberately names the grantee only:
/// the action or alias involved is not carried, so a consumer can record who
/// gained or lost access without ever holding an action reference.
public struct KeepTalkingGrantCommit: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        /// An action grant was created or merged. `scope == nil` is unrestricted.
        case actionGranted(scope: KeepTalkingActionScope?)
        case actionRevoked
        /// A tag grant was created or merged. `reachesActionCount` is how many
        /// self-hosted actions carried the tag at commit time.
        case aliasGranted(reachesActionCount: Int)
        case aliasRevoked
    }

    /// The context the change is scoped to, or `nil` for an all-contexts change.
    public let contextID: UUID?
    /// The peer whose access changed.
    public let toNodeID: UUID
    public let change: Change
    public let lane: KeepTalkingGrantLane

    public init(
        contextID: UUID?,
        toNodeID: UUID,
        change: Change,
        lane: KeepTalkingGrantLane
    ) {
        self.contextID = contextID
        self.toNodeID = toNodeID
        self.change = change
        self.lane = lane
    }
}

extension KeepTalkingActionPermissionScope {
    /// The context a scoped permission names, or `nil` for `.all`.
    var scopedContextID: UUID? {
        switch self {
            case .all: return nil
            case .context(let context): return context.id
        }
    }
}
