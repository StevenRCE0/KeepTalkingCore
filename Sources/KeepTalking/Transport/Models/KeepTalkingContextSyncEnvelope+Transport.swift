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
        }
    }
}
