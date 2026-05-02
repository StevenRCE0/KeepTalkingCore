//
//  KeepTalkingClient+MessagePagination.swift
//  KeepTalkingSDK
//
//  Cursor-paged message reads. The semantics are deliberately direction-
//  agnostic: callers ask for "messages relative to a timestamp cursor" with
//  an explicit ordering, and assemble pages into the display orientation
//  their UI wants. The chat list (docking = bottom) starts from the tail
//  and walks backward; the threads view (docking = top) starts from the
//  head and walks forward — both go through this single primitive.
//

import FluentKit
import Foundation

/// Direction the page extends from the cursor. The ordering of the
/// returned messages is in this same direction — the caller is responsible
/// for re-sorting to display order if needed.
public enum KeepTalkingMessagePageDirection: Sendable {
    /// Walk backward in time from the cursor. Returns messages with
    /// `timestamp < cursor` (or the most recent N when `cursor == nil`),
    /// sorted descending so the first element is the message just before
    /// the cursor.
    case backward
    /// Walk forward in time from the cursor. Returns messages with
    /// `timestamp > cursor` (or the oldest N when `cursor == nil`), sorted
    /// ascending so the first element is the message just after the cursor.
    case forward
}

extension KeepTalkingClient {
    /// Load one cursor-paged window of messages for a context.
    ///
    /// - Parameters:
    ///   - contextID: target context.
    ///   - cursor: timestamp boundary. Pass `nil` to read from the
    ///     extreme of the chosen direction (latest for `.backward`, oldest
    ///     for `.forward`).
    ///   - direction: walk direction relative to the cursor.
    ///   - limit: maximum messages to return.
    /// - Returns: messages in the direction's natural order. The caller
    ///   sorts ascending for canonical display when needed.
    public func loadMessagePage(
        in contextID: UUID,
        cursor: Date?,
        direction: KeepTalkingMessagePageDirection,
        limit: Int,
        lowerBound: Date? = nil,
        upperBound: Date? = nil
    ) async throws -> [KeepTalkingContextMessage] {
        var query = KeepTalkingContextMessage.query(on: localStore.database)
            .filter(\.$context.$id, .equal, contextID)

        if let lowerBound {
            query = query.filter(\.$timestamp, .greaterThanOrEqual, lowerBound)
        }
        if let upperBound {
            query = query.filter(\.$timestamp, .lessThanOrEqual, upperBound)
        }

        switch direction {
            case .backward:
                if let cursor {
                    query = query.filter(\.$timestamp, .lessThan, cursor)
                }
                query = query.sort(\.$timestamp, .descending)
            case .forward:
                if let cursor {
                    query = query.filter(\.$timestamp, .greaterThan, cursor)
                }
                query = query.sort(\.$timestamp, .ascending)
        }

        return
            try await query
            .range(..<limit)
            .all()
    }
}
