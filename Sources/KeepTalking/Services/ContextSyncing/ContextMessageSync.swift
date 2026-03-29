import CryptoKit
import Foundation

public struct KeepTalkingContextMessageSyncEvent: Codable, Sendable,
    Equatable, Hashable
{
    public let id: UUID
    public let context: UUID
    public let sender: KeepTalkingContextMessage.Sender
    public let sequence: Int
    public let content: String
    public let timestamp: Date
    public let type: KeepTalkingContextMessage.MessageType
    public let digest: Data

    public init(
        id: UUID = UUID(),
        context: UUID,
        sender: KeepTalkingContextMessage.Sender,
        sequence: Int,
        content: String,
        timestamp: Date = Date(),
        type: KeepTalkingContextMessage.MessageType = .message
    ) {
        self.id = id
        self.context = context
        self.sender = sender
        self.sequence = sequence
        self.content = content
        self.timestamp = timestamp
        self.type = type
        self.digest = Self.makeDigest(
            id: id,
            context: context,
            sender: sender,
            sequence: sequence,
            content: content,
            timestamp: timestamp,
            type: type
        )
    }

    private struct CanonicalDigestPayload: Codable {
        let id: UUID
        let context: UUID
        let sender: KeepTalkingContextMessage.Sender
        let sequence: Int
        let content: String
        let timestamp: Int64
        let type: KeepTalkingContextMessage.MessageType
    }

    private static func makeDigest(
        id: UUID,
        context: UUID,
        sender: KeepTalkingContextMessage.Sender,
        sequence: Int,
        content: String,
        timestamp: Date,
        type: KeepTalkingContextMessage.MessageType
    ) -> Data {
        let payload = CanonicalDigestPayload(
            id: id,
            context: context,
            sender: sender,
            sequence: sequence,
            content: content,
            timestamp: Int64(
                (timestamp.timeIntervalSince1970 * 1_000).rounded()
            ),
            type: type
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(payload)
        return Data(SHA256.hash(data: data))
    }
}

public struct KeepTalkingContextMessageSenderState: Codable, Sendable,
    Equatable
{
    public let sender: KeepTalkingContextMessage.Sender
    public let contiguousSequence: Int
    public let lastSequence: Int
    public let missingSequences: [ClosedRange<Int>]

    public init(
        sender: KeepTalkingContextMessage.Sender,
        contiguousSequence: Int,
        lastSequence: Int,
        missingSequences: [ClosedRange<Int>]
    ) {
        self.sender = sender
        self.contiguousSequence = contiguousSequence
        self.lastSequence = lastSequence
        self.missingSequences = normalizeRanges(missingSequences)
    }
}

public struct KeepTalkingContextMessageChunkState: Codable, Sendable,
    Equatable
{
    public let sender: KeepTalkingContextMessage.Sender
    public let index: Int
    public let firstSequence: Int
    public let lastSequence: Int
    public let count: Int
    public let digest: Data

    public init(
        sender: KeepTalkingContextMessage.Sender,
        index: Int,
        firstSequence: Int,
        lastSequence: Int,
        count: Int,
        digest: Data
    ) {
        self.sender = sender
        self.index = index
        self.firstSequence = firstSequence
        self.lastSequence = lastSequence
        self.count = count
        self.digest = digest
    }
}

public struct KeepTalkingContextMessageSyncSummary: Codable, Sendable,
    Equatable
{
    public let context: UUID
    public let senders: [KeepTalkingContextMessageSenderState]
    public let chunks: [KeepTalkingContextMessageChunkState]

    public init(
        context: UUID,
        senders: [KeepTalkingContextMessageSenderState],
        chunks: [KeepTalkingContextMessageChunkState]
    ) {
        self.context = context
        self.senders = senders.sorted {
            senderSortKey($0.sender) < senderSortKey($1.sender)
        }
        self.chunks = chunks.sorted {
            let lhsKey = senderSortKey($0.sender)
            let rhsKey = senderSortKey($1.sender)
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            return $0.index < $1.index
        }
    }
}

public struct KeepTalkingContextMessageSequenceRequest: Codable, Sendable,
    Equatable
{
    public let sender: KeepTalkingContextMessage.Sender
    public let range: ClosedRange<Int>

    public init(
        sender: KeepTalkingContextMessage.Sender,
        range: ClosedRange<Int>
    ) {
        self.sender = sender
        self.range = range
    }
}

public struct KeepTalkingContextMessageIncrementalPlan: Codable, Sendable,
    Equatable
{
    public let ranges: [KeepTalkingContextMessageSequenceRequest]

    public init(ranges: [KeepTalkingContextMessageSequenceRequest]) {
        self.ranges = ranges.sorted {
            let lhsKey = senderSortKey($0.sender)
            let rhsKey = senderSortKey($1.sender)
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            return $0.range.lowerBound < $1.range.lowerBound
        }
    }

    public init(
        local: KeepTalkingContextMessageSyncSummary,
        remote: KeepTalkingContextMessageSyncSummary
    ) {
        precondition(local.context == remote.context)

        let localBySender = Dictionary(
            uniqueKeysWithValues: local.senders.map { ($0.sender, $0) }
        )
        let remoteBySender = Dictionary(
            uniqueKeysWithValues: remote.senders.map { ($0.sender, $0) }
        )

        let requests = remoteBySender.keys.sorted(by: {
            senderSortKey($0) < senderSortKey($1)
        }).flatMap { sender in
            let remoteState = remoteBySender[sender]!
            let localState =
                localBySender[sender]
                ?? .init(
                    sender: sender,
                    contiguousSequence: 0,
                    lastSequence: 0,
                    missingSequences: []
                )
            let needed = subtractRanges(
                availableRanges(for: remoteState),
                excluding: availableRanges(for: localState)
            )

            return needed.map {
                KeepTalkingContextMessageSequenceRequest(
                    sender: sender,
                    range: $0
                )
            }
        }

        self.init(ranges: requests)
    }

    public var isEmpty: Bool {
        ranges.isEmpty
    }
}

public struct KeepTalkingContextMessageChunkRequest: Codable, Sendable,
    Equatable
{
    public let sender: KeepTalkingContextMessage.Sender
    public let index: Int

    public init(sender: KeepTalkingContextMessage.Sender, index: Int) {
        self.sender = sender
        self.index = index
    }
}

public struct KeepTalkingContextMessageChunkRepairPlan: Codable, Sendable,
    Equatable
{
    public let chunks: [KeepTalkingContextMessageChunkRequest]

    public init(chunks: [KeepTalkingContextMessageChunkRequest]) {
        self.chunks = chunks.sorted {
            let lhsKey = senderSortKey($0.sender)
            let rhsKey = senderSortKey($1.sender)
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            return $0.index < $1.index
        }
    }

    public init(
        local: KeepTalkingContextMessageSyncSummary,
        remote: KeepTalkingContextMessageSyncSummary
    ) {
        precondition(local.context == remote.context)

        let localByKey = Dictionary(
            uniqueKeysWithValues: local.chunks.map {
                (KeepTalkingContextMessageChunkKey(sender: $0.sender, index: $0.index), $0)
            }
        )
        let requests = remote.chunks.compactMap { remoteChunk in
            let key = KeepTalkingContextMessageChunkKey(
                sender: remoteChunk.sender,
                index: remoteChunk.index
            )
            guard let localChunk = localByKey[key] else {
                return KeepTalkingContextMessageChunkRequest(
                    sender: remoteChunk.sender,
                    index: remoteChunk.index
                )
            }
            guard
                localChunk.firstSequence == remoteChunk.firstSequence,
                localChunk.lastSequence == remoteChunk.lastSequence,
                localChunk.count == remoteChunk.count,
                localChunk.digest == remoteChunk.digest
            else {
                return KeepTalkingContextMessageChunkRequest(
                    sender: remoteChunk.sender,
                    index: remoteChunk.index
                )
            }
            return nil
        }

        self.init(chunks: requests)
    }

    public var isEmpty: Bool {
        chunks.isEmpty
    }
}

public struct KeepTalkingContextMessageSyncTracker: Sendable {
    public let context: UUID
    public let chunkSize: Int

    private var eventsBySender: [KeepTalkingContextMessage.Sender: [Int: KeepTalkingContextMessageSyncEvent]] =
        [:]
    private var senderStateBySender: [KeepTalkingContextMessage.Sender: KeepTalkingContextMessageSenderState] =
        [:]
    private var chunkStateByKey: [KeepTalkingContextMessageChunkKey: KeepTalkingContextMessageChunkState] =
        [:]

    public init(context: UUID, chunkSize: Int = 64) {
        precondition(chunkSize > 0)
        self.context = context
        self.chunkSize = chunkSize
    }

    public mutating func apply(_ event: KeepTalkingContextMessageSyncEvent) {
        precondition(event.context == context)
        eventsBySender[event.sender, default: [:]][event.sequence] = event
        recomputeChunk(sender: event.sender, index: chunkIndex(for: event.sequence))
        recomputeSenderState(for: event.sender)
    }

    public mutating func apply(
        _ events: [KeepTalkingContextMessageSyncEvent]
    ) {
        for event in events {
            apply(event)
        }
    }

    public mutating func replaceChunk(
        sender: KeepTalkingContextMessage.Sender,
        index: Int,
        with events: [KeepTalkingContextMessageSyncEvent]
    ) {
        for event in events {
            precondition(event.context == context)
            precondition(chunkIndex(for: event.sequence) == index)
            precondition(event.sender == sender)
        }

        var senderEvents = eventsBySender[sender, default: [:]]
        for sequence in senderEvents.keys where chunkRange(for: index).contains(sequence) {
            senderEvents.removeValue(forKey: sequence)
        }
        for event in events {
            senderEvents[event.sequence] = event
        }
        eventsBySender[sender] = senderEvents
        recomputeChunk(sender: sender, index: index)
        recomputeSenderState(for: sender)
    }

    public func events(
        for sender: KeepTalkingContextMessage.Sender,
        in range: ClosedRange<Int>
    ) -> [KeepTalkingContextMessageSyncEvent] {
        eventsBySender[sender, default: [:]]
            .values
            .filter { range.contains($0.sequence) }
            .sorted { $0.sequence < $1.sequence }
    }

    public func events(
        for sender: KeepTalkingContextMessage.Sender,
        inChunk index: Int
    ) -> [KeepTalkingContextMessageSyncEvent] {
        events(for: sender, in: chunkRange(for: index))
    }

    public func summary() -> KeepTalkingContextMessageSyncSummary {
        KeepTalkingContextMessageSyncSummary(
            context: context,
            senders: Array(senderStateBySender.values),
            chunks: Array(chunkStateByKey.values)
        )
    }

    private mutating func recomputeSenderState(
        for sender: KeepTalkingContextMessage.Sender
    ) {
        let sequences = eventsBySender[sender, default: [:]]
            .keys
            .sorted()

        guard let lastSequence = sequences.last else {
            senderStateBySender.removeValue(forKey: sender)
            return
        }

        var contiguousSequence = 0
        for sequence in sequences {
            if sequence == contiguousSequence + 1 {
                contiguousSequence = sequence
                continue
            }
            if sequence > contiguousSequence + 1 {
                break
            }
        }

        var missingSequences: [ClosedRange<Int>] = []
        var expectedSequence = 1
        for sequence in sequences {
            if sequence < expectedSequence {
                continue
            }
            if sequence > expectedSequence {
                missingSequences.append(expectedSequence...(sequence - 1))
            }
            expectedSequence = sequence + 1
        }

        senderStateBySender[sender] = KeepTalkingContextMessageSenderState(
            sender: sender,
            contiguousSequence: contiguousSequence,
            lastSequence: lastSequence,
            missingSequences: missingSequences
        )
    }

    private mutating func recomputeChunk(
        sender: KeepTalkingContextMessage.Sender,
        index: Int
    ) {
        let events = events(for: sender, inChunk: index)
        let key = KeepTalkingContextMessageChunkKey(sender: sender, index: index)

        guard
            let firstSequence = events.first?.sequence,
            let lastSequence = events.last?.sequence
        else {
            chunkStateByKey.removeValue(forKey: key)
            return
        }

        var hasher = SHA256()
        for event in events {
            hasher.update(data: event.digest)
        }

        chunkStateByKey[key] = KeepTalkingContextMessageChunkState(
            sender: sender,
            index: index,
            firstSequence: firstSequence,
            lastSequence: lastSequence,
            count: events.count,
            digest: Data(hasher.finalize())
        )
    }

    private func chunkIndex(for sequence: Int) -> Int {
        max(0, (sequence - 1) / chunkSize)
    }

    private func chunkRange(for index: Int) -> ClosedRange<Int> {
        let lowerBound = (index * chunkSize) + 1
        return lowerBound...(lowerBound + chunkSize - 1)
    }
}

private struct KeepTalkingContextMessageChunkKey: Hashable {
    let sender: KeepTalkingContextMessage.Sender
    let index: Int
}

private func availableRanges(
    for state: KeepTalkingContextMessageSenderState
) -> [ClosedRange<Int>] {
    guard state.lastSequence > 0 else {
        return []
    }

    let missingSequences = normalizeRanges(state.missingSequences)
    var available: [ClosedRange<Int>] = []
    var lowerBound = 1

    for gap in missingSequences {
        if lowerBound < gap.lowerBound {
            available.append(lowerBound...(gap.lowerBound - 1))
        }
        lowerBound = max(lowerBound, gap.upperBound + 1)
    }

    if lowerBound <= state.lastSequence {
        available.append(lowerBound...state.lastSequence)
    }

    return available
}

private func subtractRanges(
    _ ranges: [ClosedRange<Int>],
    excluding exclusions: [ClosedRange<Int>]
) -> [ClosedRange<Int>] {
    let normalizedExclusions = normalizeRanges(exclusions)

    return normalizeRanges(ranges).flatMap { range in
        var fragments = [range]
        for exclusion in normalizedExclusions {
            fragments = fragments.flatMap { fragment in
                guard
                    exclusion.lowerBound <= fragment.upperBound,
                    exclusion.upperBound >= fragment.lowerBound
                else {
                    return [fragment]
                }

                var nextFragments: [ClosedRange<Int>] = []
                if exclusion.lowerBound > fragment.lowerBound {
                    nextFragments.append(
                        fragment.lowerBound...(exclusion.lowerBound - 1)
                    )
                }
                if exclusion.upperBound < fragment.upperBound {
                    nextFragments.append(
                        (exclusion.upperBound + 1)...fragment.upperBound
                    )
                }
                return nextFragments
            }
            if fragments.isEmpty {
                break
            }
        }
        return fragments
    }
}

private func normalizeRanges(
    _ ranges: [ClosedRange<Int>]
) -> [ClosedRange<Int>] {
    let sortedRanges = ranges.sorted {
        if $0.lowerBound != $1.lowerBound {
            return $0.lowerBound < $1.lowerBound
        }
        return $0.upperBound < $1.upperBound
    }

    var normalized: [ClosedRange<Int>] = []
    for range in sortedRanges {
        guard let last = normalized.last else {
            normalized.append(range)
            continue
        }
        if range.lowerBound <= last.upperBound + 1 {
            normalized[normalized.count - 1] =
                last.lowerBound...max(last.upperBound, range.upperBound)
        } else {
            normalized.append(range)
        }
    }

    return normalized
}
