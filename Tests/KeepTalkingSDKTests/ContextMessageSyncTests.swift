import Foundation
import Testing

@testable import KeepTalkingSDK

struct ContextMessageSyncTests {
    @Test("out-of-order messages create gaps that collapse once missing events arrive")
    func outOfOrderGapTracking() {
        let context = UUID()
        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        var tracker = KeepTalkingContextMessageSyncTracker(
            context: context,
            chunkSize: 4
        )

        tracker.apply([
            event(context: context, sender: sender, sequence: 1),
            event(context: context, sender: sender, sequence: 3),
            event(context: context, sender: sender, sequence: 4),
        ])

        var summary = tracker.summary()
        let senderState = try! #require(summary.senders.first)
        #expect(senderState.contiguousSequence == 1)
        #expect(senderState.lastSequence == 4)
        #expect(senderState.missingSequences == [2...2])

        tracker.apply(event(context: context, sender: sender, sequence: 2))

        summary = tracker.summary()
        let repairedState = try! #require(summary.senders.first)
        #expect(repairedState.contiguousSequence == 4)
        #expect(repairedState.lastSequence == 4)
        #expect(repairedState.missingSequences.isEmpty)
    }

    @Test("incremental sync asks only for remote ranges that are locally missing")
    func incrementalPlanTracksRanges() {
        let context = UUID()
        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        var local = KeepTalkingContextMessageSyncTracker(
            context: context,
            chunkSize: 4
        )
        var remote = KeepTalkingContextMessageSyncTracker(
            context: context,
            chunkSize: 4
        )

        local.apply([
            event(context: context, sender: sender, sequence: 1),
            event(context: context, sender: sender, sequence: 3),
        ])
        remote.apply([
            event(context: context, sender: sender, sequence: 1),
            event(context: context, sender: sender, sequence: 2),
            event(context: context, sender: sender, sequence: 3),
            event(context: context, sender: sender, sequence: 5),
        ])

        let plan = KeepTalkingContextMessageIncrementalPlan(
            local: local.summary(),
            remote: remote.summary()
        )

        #expect(
            plan.ranges == [
                KeepTalkingContextMessageSequenceRequest(
                    sender: sender,
                    range: 2...2
                ),
                KeepTalkingContextMessageSequenceRequest(
                    sender: sender,
                    range: 5...5
                ),
            ]
        )
    }

    @Test("chunk digests are maintained incrementally and unchanged chunks stay stable")
    func chunkDigestMaintenance() {
        let context = UUID()
        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        )
        var tracker = KeepTalkingContextMessageSyncTracker(
            context: context,
            chunkSize: 4
        )

        tracker.apply([
            event(context: context, sender: sender, sequence: 1),
            event(context: context, sender: sender, sequence: 2),
            event(context: context, sender: sender, sequence: 3),
            event(context: context, sender: sender, sequence: 4),
        ])

        let firstDigest = try! #require(
            tracker.summary().chunks.first?.digest
        )

        tracker.apply(event(context: context, sender: sender, sequence: 5))

        let summary = tracker.summary()
        let firstChunk = try! #require(
            summary.chunks.first(where: { $0.index == 0 })
        )
        let secondChunk = try! #require(
            summary.chunks.first(where: { $0.index == 1 })
        )

        #expect(firstChunk.digest == firstDigest)
        #expect(firstChunk.count == 4)
        #expect(secondChunk.firstSequence == 5)
        #expect(secondChunk.lastSequence == 5)
        #expect(secondChunk.count == 1)
    }

    @Test("chunk mismatch produces a chunk repair request and replaceChunk repairs only that chunk")
    func chunkRepairFlow() {
        let context = UUID()
        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        )
        var local = KeepTalkingContextMessageSyncTracker(
            context: context,
            chunkSize: 4
        )
        var remote = KeepTalkingContextMessageSyncTracker(
            context: context,
            chunkSize: 4
        )

        remote.apply((1...8).map {
            event(context: context, sender: sender, sequence: $0)
        })
        local.apply((1...8).map {
            event(
                context: context,
                sender: sender,
                sequence: $0,
                content: $0 == 2 ? "diverged" : nil
            )
        })

        let incrementalPlan = KeepTalkingContextMessageIncrementalPlan(
            local: local.summary(),
            remote: remote.summary()
        )
        #expect(incrementalPlan.isEmpty)

        let repairPlan = KeepTalkingContextMessageChunkRepairPlan(
            local: local.summary(),
            remote: remote.summary()
        )
        #expect(
            repairPlan.chunks == [
                KeepTalkingContextMessageChunkRequest(
                    sender: sender,
                    index: 0
                )
            ]
        )

        let untouchedDigest = try! #require(
            local.summary().chunks.first(where: { $0.index == 1 })?.digest
        )
        local.replaceChunk(
            sender: sender,
            index: 0,
            with: remote.events(for: sender, inChunk: 0)
        )

        let repairedSummary = local.summary()
        #expect(
            KeepTalkingContextMessageChunkRepairPlan(
                local: repairedSummary,
                remote: remote.summary()
            ).isEmpty
        )
        #expect(repairedSummary == remote.summary())
        #expect(
            repairedSummary.chunks.first(where: { $0.index == 1 })?.digest
                == untouchedDigest
        )
    }

    private func event(
        context: UUID,
        sender: KeepTalkingContextMessage.Sender,
        sequence: Int,
        content: String? = nil
    ) -> KeepTalkingContextMessageSyncEvent {
        KeepTalkingContextMessageSyncEvent(
            id: UUID(
                uuidString: String(
                    format: "00000000-0000-0000-0000-%012d",
                    sequence
                )
            )!,
            context: context,
            sender: sender,
            sequence: sequence,
            content: content ?? "message-\(sequence)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            type: .message
        )
    }
}
