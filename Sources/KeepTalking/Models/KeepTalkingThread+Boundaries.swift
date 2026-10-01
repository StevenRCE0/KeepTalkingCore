import Foundation

/// Where a thread starts and ends, as keys — what every keyed thread read
/// works from instead of positions in a whole-context array.
///
/// `start` is nil only before the context's first message. `end` is nil for
/// the live thread, and for a stored thread whose end row is gone.
public struct KeepTalkingThreadBoundary: Sendable, Hashable, Identifiable {
    public let threadID: UUID
    public let state: KeepTalkingThreadState
    public let createdAt: Date?
    public let start: KeepTalkingMessageKey?
    public let end: KeepTalkingMessageKey?

    public init(
        threadID: UUID,
        state: KeepTalkingThreadState,
        createdAt: Date?,
        start: KeepTalkingMessageKey?,
        end: KeepTalkingMessageKey?
    ) {
        self.threadID = threadID
        self.state = state
        self.createdAt = createdAt
        self.start = start
        self.end = end
    }

    public var id: UUID { threadID }

    /// The thread's rows, or nil when it does not resolve — the same cases
    /// `resolvedMessageRange(in:)` returns nil for: no start, a stored
    /// thread with no end, or an end before the start.
    public var range: KeepTalkingMessageRange? {
        guard let start else { return nil }
        switch state {
            case .contextMain:
                return .thread(start: start, end: nil)
            case .stored, .archived:
                guard let end, start <= end else { return nil }
                return .thread(start: start, end: end)
        }
    }

    /// The thread that owns `key`, by the rule the index-based lookup used:
    /// the narrowest containing thread, a frozen one before the live one,
    /// the oldest of what is left. Without `counts` narrowness is judged by
    /// the keys — later start, then earlier end — which agrees whenever
    /// threads nest or partition.
    public static func owner(
        of key: KeepTalkingMessageKey,
        among boundaries: [KeepTalkingThreadBoundary],
        counts: [UUID: Int]? = nil
    ) -> KeepTalkingThreadBoundary? {
        boundaries
            .filter { $0.range?.contains(key) ?? false }
            .sorted { lhs, rhs in
                if let counts, let l = counts[lhs.threadID], let r = counts[rhs.threadID], l != r {
                    return l < r
                }
                if counts == nil {
                    if let l = lhs.start, let r = rhs.start, l != r { return l > r }
                    switch (lhs.end, rhs.end) {
                        case (.some(let l), .some(let r)) where l != r: return l < r
                        case (.some, .none): return true
                        case (.none, .some): return false
                        default: break
                    }
                }
                if lhs.state != rhs.state {
                    return lhs.state != .contextMain
                }
                return (lhs.createdAt ?? .distantPast) < (rhs.createdAt ?? .distantPast)
            }
            .first
    }
}

/// A thread's place in the context: how many rows precede its first, and
/// how many it holds. Rows the timeline draws at `offset` through
/// `offset + count - 1`.
public struct KeepTalkingThreadSpan: Sendable, Hashable, Identifiable {
    public let boundary: KeepTalkingThreadBoundary
    public let offset: Int
    public let count: Int

    public init(boundary: KeepTalkingThreadBoundary, offset: Int, count: Int) {
        self.boundary = boundary
        self.offset = offset
        self.count = count
    }

    public var id: UUID { boundary.threadID }
    public var threadID: UUID { boundary.threadID }
    public var lastOffset: Int { offset + count - 1 }
}

/// Every resolving thread of a context laid over its rows, by start.
public struct KeepTalkingThreadLayout: Sendable, Hashable {
    public let total: Int
    public let spans: [KeepTalkingThreadSpan]

    public init(total: Int, spans: [KeepTalkingThreadSpan]) {
        self.total = total
        self.spans = spans
    }

    public static let empty = Self(total: 0, spans: [])

    public func span(for threadID: UUID) -> KeepTalkingThreadSpan? {
        spans.first { $0.threadID == threadID }
    }
}
