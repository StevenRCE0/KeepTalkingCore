import FluentKit
import Foundation

extension KeepTalkingClient {
    /// Stores a mark message in the context. The mark is a plain context message
    /// whose type encodes the annotation intent and target message ID. It travels
    /// through normal context sync so every node receives it.
    func storeContextMark(
        _ type: KeepTalkingContextMessage.MessageType,
        in context: KeepTalkingContext
    ) async throws {
        let mark = KeepTalkingContextMessage(
            context: context,
            sender: .node(node: config.node),
            content: "",
            type: type
        )
        try await mark.save(on: localStore.database)
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

        let marks = try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$context.$id == contextID)
            .all()
            .filter { msg in
                guard let id = msg.id else { return false }
                guard !consumed.contains(id) else { return false }
                switch msg.type {
                    case .markTurningPoint, .markChitterChatter: return true
                    default: return false
                }
            }

        guard !marks.isEmpty else { return }

        var newlyConsumed: [UUID] = []

        for mark in marks {
            guard let markID = mark.id else { continue }
            do {
                switch mark.type {
                    case .markTurningPoint(let messageID, let previousTopicName):
                        let storedThread = try await markTurningPoint(
                            at: messageID,
                            in: contextID
                        )
                        if let threadID = storedThread.id {
                            try await setAlias(previousTopicName, for: .thread(threadID))
                            onMappingsChanged?()
                        }
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
}
