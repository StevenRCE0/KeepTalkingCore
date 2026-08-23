import Foundation

/// The output the powerhouse agent produces: everything needed to scaffold a
/// workspace in one shot. Pure value type — the app-side service owns
/// persistence and execution.
public struct KeepTalkingWorkspacePlan: Codable, Sendable {

    /// A peer SLOT in the plan — a placeholder role ("ghost peer") with an
    /// alias and expected capabilities, not a real node. It never touches
    /// `kt_nodes` or `kt_node_relation`; when the user binds the slot to a
    /// real node, the app runs the actual trust/provision flows through the
    /// existing mechanisms and records the binding at the app level.
    public struct Peer: Codable, Sendable, Identifiable, Hashable {
        public var id: UUID
        public var alias: String
        public var expectedCapabilities: [String]
        /// Action slot IDs granted TO this peer — local actions (existing or
        /// to-create) the peer's agent can invoke once the slot is bound.
        public var grantedActions: [UUID]

        public init(
            id: UUID = UUID(),
            alias: String,
            expectedCapabilities: [String] = [],
            grantedActions: [UUID] = []
        ) {
            self.id = id
            self.alias = alias
            self.expectedCapabilities = expectedCapabilities
            self.grantedActions = grantedActions
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            alias = try container.decode(String.self, forKey: .alias)
            expectedCapabilities = try container.decode([String].self, forKey: .expectedCapabilities)
            grantedActions = try container.decodeIfPresent([UUID].self, forKey: .grantedActions) ?? []
        }
    }

    /// An action SLOT in the plan.
    public struct Action: Codable, Sendable, Identifiable, Hashable {
        public var id: UUID
        public var name: String
        public var description: String?
        public var source: Source

        public enum Source: Codable, Sendable, Hashable {
            /// Already in the user's inventory.
            case existing(actionID: UUID)
            /// To be built by the user's own agent (Auto Curate) after setup.
            case create
            /// Expected from a peer slot's agent once the slot is bound.
            case fromPeer(peerID: UUID)
        }

        public init(
            id: UUID = UUID(),
            name: String,
            description: String? = nil,
            source: Source
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.source = source
        }
    }

    /// An SOP / workflow note to attach to the context.
    public struct SideNoteEntry: Codable, Sendable, Hashable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var contextName: String
    public var contextDescription: String?
    public var tags: [String]
    public var peers: [Peer]
    public var actions: [Action]
    public var sideNotes: [SideNoteEntry]
    public var rationale: String?

    public init(
        contextName: String,
        contextDescription: String? = nil,
        tags: [String] = [],
        peers: [Peer] = [],
        actions: [Action] = [],
        sideNotes: [SideNoteEntry] = [],
        rationale: String? = nil
    ) {
        self.contextName = contextName
        self.contextDescription = contextDescription
        self.tags = tags
        self.peers = peers
        self.actions = actions
        self.sideNotes = sideNotes
        self.rationale = rationale
    }
}
