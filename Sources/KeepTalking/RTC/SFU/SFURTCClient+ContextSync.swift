import Foundation

extension KeepTalkingRTCClient {
    func peerNodes(in envelope: KeepTalkingContextSyncEnvelope) -> [UUID] {
        switch envelope {
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
            case .recentAttachmentsRequest(let request):
                return [request.requester, request.recipient]
            case .attachmentsResult(let result):
                return [result.requester, result.responder]
        }
    }
}
