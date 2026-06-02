import Foundation

extension KeepTalkingContextSyncEnvelope {
    public var participantNodeIDs: [UUID] {
        switch self {
            case .summaryRequest(let request):
                return [request.requester, request.recipient]
            case .summaryResult(let result):
                return [result.requester, result.responder]
            case .tailRequest(let request):
                return [request.requester, request.recipient]
            case .chunkRequest(let request):
                return [request.requester, request.recipient]
            case .messagesResult(let result):
                return [result.requester, result.responder]
            case .attachmentRequest(let request):
                return [request.requester]
            case .attachmentRecordsRequest(let request):
                return [request.requester, request.recipient]
            case .attachmentRecordsResult(let result):
                return [result.requester, result.responder]
            case .sideNotesRequest(let request):
                return [request.requester, request.recipient]
            case .sideNotesResult(let result):
                return [result.requester, result.responder]
            case .transcriptSummaryRequest(let request):
                return [request.requester, request.recipient]
            case .transcriptSummaryResult(let result):
                return [result.requester, result.responder]
            case .transcriptTailRequest(let request):
                return [request.requester, request.recipient]
            case .transcriptChunkRequest(let request):
                return [request.requester, request.recipient]
            case .transcriptLinesResult(let result):
                return [result.requester, result.responder]
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
            case .sideNotesRequest(let request):
                return request.context
            case .sideNotesResult(let result):
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
        }
    }
}
