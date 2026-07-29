import Foundation

extension KeepTalkingContextSyncEnvelope {
    public var targetPeerNodeID: UUID? {
        switch self {
            case .summaryRequest(let request):
                return request.recipient
            case .summaryResult(let result):
                return result.requester
            case .tailRequest(let request):
                return request.recipient
            case .chunkRequest(let request):
                return request.recipient
            case .messagesResult(let result):
                return result.requester
            case .attachmentRequest:
                return nil
            case .attachmentRecordsRequest(let request):
                return request.recipient
            case .attachmentRecordsResult(let result):
                return result.requester
            case .transcriptSummaryRequest(let request):
                return request.recipient
            case .transcriptSummaryResult(let result):
                return result.requester
            case .transcriptTailRequest(let request):
                return request.recipient
            case .transcriptChunkRequest(let request):
                return request.recipient
            case .transcriptLinesResult(let result):
                return result.requester
            case .sideNotesPush:
                return nil
            case .failureResult(let result):
                return result.requester
        }
    }

    var contextID: UUID {
        switch self {
            case .summaryRequest(let request):
                return request.context
            case .summaryResult(let result):
                return result.context
            case .tailRequest(let request):
                return request.context
            case .chunkRequest(let request):
                return request.context
            case .messagesResult(let result):
                return result.context
            case .attachmentRequest(let request):
                return request.context
            case .attachmentRecordsRequest(let request):
                return request.context
            case .attachmentRecordsResult(let result):
                return result.context
            case .transcriptSummaryRequest(let request):
                return request.context
            case .transcriptSummaryResult(let result):
                return result.context
            case .transcriptTailRequest(let request):
                return request.context
            case .transcriptChunkRequest(let request):
                return request.context
            case .transcriptLinesResult(let result):
                return result.context
            case .sideNotesPush(let push):
                return push.context
            case .failureResult(let result):
                return result.context
        }
    }
}
