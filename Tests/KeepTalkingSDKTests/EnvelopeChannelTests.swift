import Foundation
import Testing

@testable import KeepTalkingSDK

struct EnvelopeChannelTests {
    @Test("config exposes a context-scoped blob channel label")
    func configExposesBlobChannelLabel() throws {
        let contextID = UUID(uuidString: "01000000-0000-0000-0000-000000000000")!
        let config = KeepTalkingConfig(
            signalURL: try #require(URL(string: "ws://127.0.0.1")),
            contextID: contextID,
            node: UUID(uuidString: "02000000-0000-0000-0000-000000000000")!
        )

        #expect(
            config.blobChannelLabel
                == "keep-talking.blob.\(contextID.uuidString.lowercased())"
        )
    }

    @Test("context sync envelopes use the chat channel")
    func contextSyncUsesChatChannel() {
        let envelope = KeepTalkingContextSyncEnvelope.summaryRequest(
            KeepTalkingContextSyncSummaryRequest(
                context: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!,
                requester: UUID(uuidString: "20000000-0000-0000-0000-000000000000")!,
                recipient: UUID(uuidString: "30000000-0000-0000-0000-000000000000")!
            )
        )

        #expect(envelope.channel == KeepTalkingEnvelopeChannel.chat)
    }

    @Test("attachment envelopes use the chat channel")
    func attachmentUsesChatChannel() {
        let envelope = KeepTalkingContextAttachmentDTO(
            id: UUID(uuidString: "12000000-0000-0000-0000-000000000000")!,
            contextID: UUID(uuidString: "11000000-0000-0000-0000-000000000000")!,
            parentMessageID: UUID(
                uuidString: "13000000-0000-0000-0000-000000000000"
            )!,
            blobID: "blob-1",
            filename: "image.png",
            mimeType: "image/png",
            byteCount: 1024,
            sortIndex: 0
        )

        #expect(envelope.channel == KeepTalkingEnvelopeChannel.chat)
    }

    @Test("action call envelopes stay on the action channel")
    func actionCallUsesActionChannel() {
        let envelope = KeepTalkingActionCallRequest(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000000")!,
            contextID: UUID(uuidString: "60000000-0000-0000-0000-000000000000")!,
            callerNodeID: UUID(uuidString: "70000000-0000-0000-0000-000000000000")!,
            targetNodeID: UUID(uuidString: "80000000-0000-0000-0000-000000000000")!,
            call: KeepTalkingActionCall(
                action: UUID(uuidString: "40000000-0000-0000-0000-000000000000")!
            )
        )

        #expect(envelope.channel == KeepTalkingEnvelopeChannel.actionCall)
    }

    @Test("request acknowledgements stay on the action channel")
    func requestAcknowledgementUsesActionChannel() {
        let envelope = KeepTalkingRequestAck(
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

        #expect(envelope.channel == KeepTalkingEnvelopeChannel.actionCall)
    }
}
