import AIProxy
import Foundation

enum AskForFileToolError: Error, Equatable {
    case incompleteTransfer(blobIDs: [String])
}

private struct AskForFileToolResultPayload: Decodable {
    let status: String?
    let contextID: String?
    let attachments: [Attachment]

    struct Attachment: Decodable {
        let blobID: String
        let size: Int?

        private enum CodingKeys: String, CodingKey {
            case blobID = "blob_id"
            case size
        }
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case contextID = "context_id"
        case attachments
    }
}

extension KeepTalkingClient {
    func adaptMidTurnInjectionMessages(
        _ executions: [AIOrchestrator.ToolExecution],
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        context: KeepTalkingContext,
        transferReceiptTimeout: Duration = .seconds(15)
    ) async throws -> [AIMessage] {
        let contextID = try context.requireID()
        var messages: [AIMessage] = []

        for execution in executions {
            guard
                let route = runtimeCatalog.routesByFunctionName[
                    execution.toolCall.name
                ],
                case .actionProxy(let definition) = route
            else {
                continue
            }
            guard definition.source == .primitive,
                definition.targetName
                    == KeepTalkingPrimitiveActionKind.askForFile.rawValue
            else {
                continue
            }
            guard
                let payload = askForFileToolResultPayload(
                    from: execution.messages
                ),
                payload.status == "sent_to_context",
                payload.contextID == contextID.uuidString.lowercased()
            else {
                continue
            }

            messages.append(
                contentsOf: try await injectedAskForFileMessages(
                    payload.attachments,
                    in: contextID,
                    timeout: transferReceiptTimeout
                )
            )
        }

        return messages
    }
}

extension KeepTalkingClient {
    fileprivate func askForFileToolResultPayload(
        from messages: [AIMessage]
    ) -> AskForFileToolResultPayload? {
        let textContent = messages.compactMap { message -> String? in
            guard message.role == .tool, let content = message.content else { return nil }
            return text(from: content)
        }

        for candidate in textContent {
            guard
                let data = candidate.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let contentArray = json["content"] as? [String]
            else {
                continue
            }

            for value in contentArray {
                guard let payloadData = value.data(using: .utf8) else {
                    continue
                }
                if let payload = try? JSONDecoder().decode(
                    AskForFileToolResultPayload.self,
                    from: payloadData
                ) {
                    return payload
                }
            }
        }

        for candidate in textContent {
            guard let data = candidate.data(using: .utf8) else {
                continue
            }
            if let payload = try? JSONDecoder().decode(
                AskForFileToolResultPayload.self,
                from: data
            ) {
                return payload
            }
        }

        return nil
    }

    fileprivate func text(from content: AIMessage.Content) -> String? {
        let trimmed = content.text.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate func injectedAskForFileMessages(
        _ attachments: [AskForFileToolResultPayload.Attachment],
        in contextID: UUID,
        timeout: Duration = .seconds(15)
    ) async throws -> [AIMessage] {
        let orderedUniqueAttachments = orderedUniqueInjectableAttachments(
            attachments
        )
        guard !orderedUniqueAttachments.isEmpty else {
            return []
        }

        let orderedBlobIDs = orderedUniqueAttachments.map(\.blobID)
        let deadline = ContinuousClock.now + timeout

        while true {
            let contextAttachments = try await contextAttachments(in: contextID)
            let attachmentsByBlobID = Dictionary(
                contextAttachments.map { ($0.blobID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let matches = orderedBlobIDs.compactMap { attachmentsByBlobID[$0] }

            if !matches.isEmpty {
                do {
                    try await requestAttachmentBlobsIfNeeded(
                        for: matches,
                        in: contextID
                    )
                } catch {
                    rtcClient.debug(
                        "ask-for-file receipt wait could not request blobs error=\(error.localizedDescription)"
                    )
                }
            }

            let blobRecords = try await blobRecordsByBlobID(
                matches.map(\.blobID)
            )
            var readyBlobIDs: Set<String> = []
            var injectedMessages: [AIMessage] = []
            injectedMessages.reserveCapacity(orderedBlobIDs.count)
            for blobID in orderedBlobIDs {
                guard let attachment = attachmentsByBlobID[blobID],
                    let blobRecord = blobRecords[blobID],
                    blobRecord.availability == .ready,
                    let data = try? blobStore.read(
                        relativePath: blobRecord.relativePath,
                        blobID: blobID
                    )
                else {
                    continue
                }
                injectedMessages.append(
                    nativeContextAttachmentUserMessage(
                        attachment: attachment,
                        data: data
                    )
                )
                readyBlobIDs.insert(blobID)
            }

            if injectedMessages.count == orderedBlobIDs.count {
                return injectedMessages
            }

            guard ContinuousClock.now < deadline else {
                let pendingBlobIDs = orderedBlobIDs.filter {
                    !readyBlobIDs.contains($0)
                }
                throw AskForFileToolError.incompleteTransfer(
                    blobIDs: pendingBlobIDs
                )
            }

            try await Task.sleep(for: .milliseconds(150))
        }
    }

    fileprivate func orderedUniqueInjectableAttachments(
        _ attachments: [AskForFileToolResultPayload.Attachment]
    ) -> [AskForFileToolResultPayload.Attachment] {
        var seenBlobIDs: Set<String> = []
        var ordered: [AskForFileToolResultPayload.Attachment] = []

        for attachment in attachments {
            guard attachment.size ?? 0 <= Self.maxAINativeAttachmentBytes else {
                continue
            }
            guard seenBlobIDs.insert(attachment.blobID).inserted else {
                continue
            }
            ordered.append(attachment)
        }

        return ordered
    }
}
