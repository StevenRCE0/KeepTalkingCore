import Foundation

public struct KeepTalkingGrantTransaction: Sendable, Equatable {
    public struct Key: Sendable, Hashable {
        public let contextID: UUID?
        public let actionID: UUID
        public let nodeID: UUID

        public init(contextID: UUID? = nil, actionID: UUID, nodeID: UUID) {
            self.contextID = contextID
            self.actionID = actionID
            self.nodeID = nodeID
        }
    }

    public enum Change: Sendable, Hashable {
        case grant(KeepTalkingActionScope?)
        case revoke
    }

    public struct Entry: Sendable, Hashable {
        public let key: Key
        public let change: Change

        public init(key: Key, change: Change) {
            self.key = key
            self.change = change
        }
    }

    private var changes: [Key: Change] = [:]

    public init() {}

    public var entries: [Entry] {
        changes.map { Entry(key: $0.key, change: $0.value) }
            .sorted {
                ($0.key.contextID?.uuidString ?? "", $0.key.actionID.uuidString, $0.key.nodeID.uuidString)
                    < ($1.key.contextID?.uuidString ?? "", $1.key.actionID.uuidString, $1.key.nodeID.uuidString)
            }
    }

    public var isEmpty: Bool { changes.isEmpty }

    public mutating func grant(
        in contextID: UUID? = nil,
        actionID: UUID,
        to nodeID: UUID,
        permission: KeepTalkingActionScope? = nil
    ) {
        changes[Key(contextID: contextID, actionID: actionID, nodeID: nodeID)] =
            .grant(permission)
    }

    public mutating func grant(
        actionID: UUID,
        to nodeID: UUID,
        scope: KeepTalkingActionPermissionScope,
        permission: KeepTalkingActionScope? = nil
    ) throws {
        switch scope {
            case .all:
                grant(actionID: actionID, to: nodeID, permission: permission)
            case .context(let context):
                guard let contextID = context.id else {
                    throw KeepTalkingClientError.missingContext(nil)
                }
                grant(
                    in: contextID,
                    actionID: actionID,
                    to: nodeID,
                    permission: permission
                )
        }
    }

    public mutating func revoke(
        in contextID: UUID? = nil,
        actionID: UUID,
        from nodeID: UUID
    ) {
        changes[Key(contextID: contextID, actionID: actionID, nodeID: nodeID)] =
            .revoke
    }

    public mutating func merge(_ entry: Entry) {
        changes[entry.key] = entry.change
    }

    public mutating func merge(_ other: Self) {
        changes.merge(other.changes) { _, latest in latest }
    }

    @discardableResult
    public mutating func invalidate(_ key: Key) -> Bool {
        changes.removeValue(forKey: key) != nil
    }

    @discardableResult
    public mutating func invalidate(
        where predicate: (Entry) -> Bool
    ) -> Set<Key> {
        let keys = Set(entries.lazy.filter(predicate).map(\.key))
        keys.forEach { changes[$0] = nil }
        return keys
    }

    public func change(for key: Key) -> Change? {
        changes[key]
    }
}
