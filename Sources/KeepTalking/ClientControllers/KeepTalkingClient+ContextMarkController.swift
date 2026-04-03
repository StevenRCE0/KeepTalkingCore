import FluentKit
import Foundation

extension KeepTalkingClient {
    /// Stores a mark message in the context. The mark is a plain context message
    /// whose type encodes the annotation intent and target message ID. It travels
    /// through normal context sync so every node receives it.
    func storeContextMark(
        _ type: KeepTalkingContextMessage.MessageType,
        in context: KeepTalkingContext
    ) async throws -> Bool {
        let contextID = try context.requireID()
        if let targetMessageID = markedMessageID(for: type) {
            let existingMarks = try await KeepTalkingContextMessage.query(
                on: localStore.database
            )
            .filter(\.$context.$id == contextID)
            .all()

            if existingMarks.contains(where: {
                markedMessageID(for: $0.type) == targetMessageID
            }) {
                return false
            }
        }

        let mark = KeepTalkingContextMessage(
            context: context,
            sender: .node(node: config.node),
            content: "",
            type: type
        )
        try await mark.save(on: localStore.database)
        return true
    }

    /// Finds all mark messages in the context that this node hasn't consumed yet,
    /// applies their effects locally, and records them as consumed.
    ///
    /// Call this after storing a mark locally, and after every context sync.
    func consumePendingMarks(in contextID: UUID) async throws {
        let db = localStore.database

        guard let context = try await KeepTalkingContext.find(contextID, on: db) else {
            return
        }
        let consumed = Set(context.consumedMarks ?? [])

        let allMarks = try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$context.$id == contextID)
            .all()

        let annotationMarks = allMarks.filter { msg in
            switch msg.type {
                case .markTurningPoint, .markChitterChatter: return true
                default: return false
            }
        }

        let consumedTargetMessageIDs = Set<UUID>(
            annotationMarks.compactMap { msg in
                guard let id = msg.id, consumed.contains(id) else {
                    return nil
                }
                return markedMessageID(for: msg.type)
            }
        )

        let marks = annotationMarks
            .filter { msg in
                guard let id = msg.id else { return false }
                guard !consumed.contains(id) else { return false }
                switch msg.type {
                    case .markTurningPoint, .markChitterChatter: return true
                    default: return false
                }
            }
            .sorted {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp < $1.timestamp
                }
                return ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
            }

        guard !marks.isEmpty else { return }

        var newlyConsumed: [UUID] = []
        var seenTargetMessageIDs = consumedTargetMessageIDs

        for mark in marks {
            guard let markID = mark.id else { continue }
            if let targetMessageID = markedMessageID(for: mark.type) {
                guard !seenTargetMessageIDs.contains(targetMessageID) else {
                    newlyConsumed.append(markID)
                    continue
                }
                seenTargetMessageIDs.insert(targetMessageID)
            }
            do {
                switch mark.type {
                    case .markTurningPoint(
                        let messageID,
                        let previousTopicName,
                        let currentTopicName
                    ):
                        try await applyTurningPointMark(
                            at: messageID,
                            in: contextID,
                            previousTopicName: previousTopicName,
                            currentTopicName: currentTopicName
                        )
                        onThreadsChanged?()
                    case .markChitterChatter(let messageID):
                        try await setChitterChatter(
                            messageID: messageID,
                            in: contextID,
                            marked: true
                        )
                        onThreadsChanged?()
                    default:
                        break
                }
                newlyConsumed.append(markID)
            } catch {
                onLog?("[marks] failed to consume mark=\(markID.uuidString.lowercased()) error=\(error.localizedDescription)")
            }
        }

        guard !newlyConsumed.isEmpty else { return }

        context.consumedMarks = (context.consumedMarks ?? []) + newlyConsumed
        try await context.save(on: db)
    }

    private func markedMessageID(
        for type: KeepTalkingContextMessage.MessageType
    ) -> UUID? {
        switch type {
            case .markTurningPoint(let messageID, _, _):
                return messageID
            case .markChitterChatter(let messageID):
                return messageID
            default:
                return nil
        }
    }
}
