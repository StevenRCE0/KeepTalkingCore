import Foundation
import Testing

@testable import KeepTalkingSDK

struct EnvelopeChannelTests {
    @Test("context sync envelopes use the chat channel")
    func contextSyncUsesChatChannel() {
        let envelope = KeepTalkingP2PEnvelope.contextSync(
            .summaryRequest(
                KeepTalkingContextSyncSummaryRequest(
                    context: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!,
                    requester: UUID(uuidString: "20000000-0000-0000-0000-000000000000")!,
                    recipient: UUID(uuidString: "30000000-0000-0000-0000-000000000000")!
                )
            )
        )

        #expect(envelope.channel == KeepTalkingEnvelopeChannel.chat)
    }

    @Test("action call envelopes stay on the action channel")
    func actionCallUsesActionChannel() {
        let envelope = KeepTalkingP2PEnvelope.actionCallRequest(
            KeepTalkingActionCallRequest(
                id: UUID(uuidString: "50000000-0000-0000-0000-000000000000")!,
                contextID: UUID(uuidString: "60000000-0000-0000-0000-000000000000")!,
                callerNodeID: UUID(uuidString: "70000000-0000-0000-0000-000000000000")!,
                targetNodeID: UUID(uuidString: "80000000-0000-0000-0000-000000000000")!,
                call: KeepTalkingActionCall(
                    action: UUID(uuidString: "40000000-0000-0000-0000-000000000000")!
                )
            )
        )

        #expect(envelope.channel == KeepTalkingEnvelopeChannel.actionCall)
    }

    @Test("request acknowledgements stay on the action channel")
    func requestAcknowledgementUsesActionChannel() {
        let envelope = KeepTalkingP2PEnvelope.requestAck(
            KeepTalkingRequestAck(
                requestID: UUID(
                    uuidString: "90000000-0000-0000-0000-000000000000"
                )!,
                contextID: UUID(
                    uuidString: "A0000000-0000-0000-0000-000000000000"
                )!,
                callerNodeID: UUID(
                    uuidString: "B0000000-0000-0000-0000-000000000000"
                )!,
                targetNodeID: UUID(
                    uuidString: "C0000000-0000-0000-0000-000000000000"
                )!,
                kind: .actionCall,
                state: .received,
                actionID: UUID(
                    uuidString: "D0000000-0000-0000-0000-000000000000"
                )!
            )
        )

        #expect(envelope.channel == KeepTalkingEnvelopeChannel.actionCall)
    }
}
