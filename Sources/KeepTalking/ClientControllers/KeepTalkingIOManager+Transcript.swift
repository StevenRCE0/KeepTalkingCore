import AIProxy
import FluentKit
import Foundation

extension KeepTalkingIOManager {
    func transcriptMessagesForProducedResources(
        from executions: [AIOrchestrator.ToolExecution],
        context: KeepTalkingContext
    ) async -> [AIMessage] {
        guard let contextID = try? context.requireID() else { return [] }
        var messages: [AIMessage] = []
        for resource in producedResources(from: executions) {
            if let byteCount = resource.byteCount,
                byteCount > KeepTalkingClient.maxAINativeAttachmentBytes
            {
                client.rtcClient.debug(
                    "[io/inject] skipped oversized produced resource handle=\(resource.handle) bytes=\(byteCount)"
                )
                continue
            }
            if let message = await transcriptMessage(for: resource, contextID: contextID) {
                messages.append(message)
            } else {
                client.rtcClient.debug(
                    "[io/inject] skipped unreadable produced resource handle=\(resource.handle) kind=\(resource.kind)"
                )
            }
        }
        return messages
    }

    private func producedResources(
        from executions: [AIOrchestrator.ToolExecution]
    ) -> [KTResourceManifest.AgentResource] {
        executions.flatMap { execution -> [KTResourceManifest.AgentResource] in
            guard let text = ACTAgentResultExtractor.text(from: execution.messages),
                let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let resources = json["produced_resources"] as? [[String: Any]]
            else { return [] }
            return resources.compactMap(KTResourceManifest.AgentResource.init(jsonObject:))
        }
    }

    private func transcriptMessage(
        for resource: KTResourceManifest.AgentResource,
        contextID: UUID
    ) async -> AIMessage? {
        guard let handle = KTResourceManifest.resolveAgentHandle(resource.handle)?.id
        else { return nil }
        let leadText = resource.injectedContentLeadText

        switch resource.kind {
            case "attachment":
                guard let attachment = try? await client.contextAttachment(handle, in: contextID),
                    let blobRecord = try? await KeepTalkingBlobRecord.query(
                        on: client.localStore.database
                    )
                    .filter(\.$id, .equal, attachment.blobID).first(),
                    blobRecord.availability == .ready,
                    let data = try? client.blobStore.read(
                        relativePath: blobRecord.relativePath, blobID: attachment.blobID)
                else { return nil }
                return nativeUserMessage(
                    filename: resource.name,
                    mimeType: attachment.mimeType,
                    data: data,
                    leadText: leadText)

            case "otb":
                guard
                    let staged = await stagedResource(handle: handle, filename: resource.name),
                    let data = try? Data(contentsOf: staged.url)
                else { return nil }
                return nativeUserMessage(
                    filename: staged.filename,
                    mimeType: resource.mimeType ?? staged.mimeType,
                    data: data,
                    leadText: leadText)

            default:
                return nil
        }
    }
}
