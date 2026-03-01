import FluentKit
import Foundation
import MCP

extension KeepTalkingClient {
    private static let actionCatalogResultTimeoutSeconds: TimeInterval = 15
    private static let actionCatalogSkillManifestMaxCharacters = 20_000
    private static let actionCatalogSkillFileMaxCharacters = 30_000

    func executeActionCatalogRequest(
        _ request: KeepTalkingActionCatalogRequest,
        context: KeepTalkingContext?
    ) async -> KeepTalkingActionCatalogResult {
        do {
            let remoteNode = try await ensure(
                request.callerNodeID,
                for: KeepTalkingNode.self
            )

            let deduplicatedQueries = deduplicatedCatalogQueries(
                request.queries
            )
            var items: [KeepTalkingActionCatalogItemResult] = []
            items.reserveCapacity(deduplicatedQueries.count)

            for query in deduplicatedQueries {
                let item = await executeActionCatalogQuery(
                    query,
                    remoteNode: remoteNode,
                    context: context
                )
                items.append(item)
            }

            return KeepTalkingActionCatalogResult(
                requestID: request.id,
                contextID: request.contextID,
                callerNodeID: request.callerNodeID,
                targetNodeID: request.targetNodeID,
                items: items,
                isError: false
            )
        } catch {
            return KeepTalkingActionCatalogResult(
                requestID: request.id,
                contextID: request.contextID,
                callerNodeID: request.callerNodeID,
                targetNodeID: request.targetNodeID,
                items: [],
                isError: true,
                errorMessage: error.localizedDescription
            )
        }
    }

    func handleIncomingActionCatalogRequest(
        _ request: KeepTalkingActionCatalogRequest
    ) async throws {
        let context = try await ensure(
            request.contextID,
            for: KeepTalkingContext.self
        )

        let result = await executeActionCatalogRequest(
            request,
            context: context
        )
        let encryptedResult = try await encryptActionCatalogResultEnvelope(result)
        try rtcClient.sendEnvelope(.encryptedActionCatalogResult(encryptedResult))
    }

    func dispatchActionCatalogRequest(
        targetNodeID: UUID,
        queries: [KeepTalkingActionCatalogQuery],
        context: KeepTalkingContext
    ) async throws -> KeepTalkingActionCatalogResult {
        let request = KeepTalkingActionCatalogRequest(
            contextID: try context.requireID(),
            callerNodeID: config.node,
            targetNodeID: targetNodeID,
            queries: queries
        )

        if targetNodeID == config.node {
            return await executeActionCatalogRequest(request, context: context)
        }

        let encryptedRequest = try await encryptActionCatalogRequestEnvelope(
            request
        )
        try rtcClient.sendEnvelope(
            .encryptedActionCatalogRequest(encryptedRequest)
        )

        return try await waitForActionCatalogResult(
            requestID: request.id,
            timeoutSeconds: Self.actionCatalogResultTimeoutSeconds
        )
    }

    func waitForActionCatalogResult(
        requestID: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> KeepTalkingActionCatalogResult {
        try await withThrowingTaskGroup(of: KeepTalkingActionCatalogResult.self)
        { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw KeepTalkingClientError.actionCatalogTimeout(requestID)
                }
                return try await withCheckedThrowingContinuation {
                    (
                        continuation: CheckedContinuation<
                            KeepTalkingActionCatalogResult, Error
                        >
                    ) in
                    self.actionCatalogQueue.sync {
                        self.pendingActionCatalogResults[requestID] =
                            continuation
                    }
                }
            }

            group.addTask { [weak self] in
                try await Task.sleep(
                    nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)
                )
                self?.failPendingActionCatalogRequest(
                    requestID: requestID,
                    error: KeepTalkingClientError.actionCatalogTimeout(requestID)
                )
                throw KeepTalkingClientError.actionCatalogTimeout(requestID)
            }

            let first = try await group.next()
            group.cancelAll()
            guard let first else {
                throw KeepTalkingClientError.actionCatalogTimeout(requestID)
            }
            return first
        }
    }

    func resolvePendingActionCatalogResult(
        _ result: KeepTalkingActionCatalogResult
    ) -> Bool {
        actionCatalogQueue.sync {
            guard
                let continuation = pendingActionCatalogResults.removeValue(
                    forKey: result.requestID
                )
            else {
                return false
            }
            continuation.resume(returning: result)
            return true
        }
    }

    func failPendingActionCatalogRequest(requestID: UUID, error: Error) {
        actionCatalogQueue.sync {
            guard
                let continuation = pendingActionCatalogResults.removeValue(
                    forKey: requestID
                )
            else {
                return
            }
            continuation.resume(throwing: error)
        }
    }

    func failAllPendingActionCatalogRequests(error: Error) {
        actionCatalogQueue.sync {
            let pending = pendingActionCatalogResults
            pendingActionCatalogResults.removeAll()
            for continuation in pending.values {
                continuation.resume(throwing: error)
            }
        }
    }

    private func deduplicatedCatalogQueries(
        _ queries: [KeepTalkingActionCatalogQuery]
    ) -> [KeepTalkingActionCatalogQuery] {
        var seen: Set<String> = []
        var result: [KeepTalkingActionCatalogQuery] = []
        result.reserveCapacity(queries.count)

        for query in queries {
            let argumentsKey: String
            let normalizedArguments = normalizedSkillFileQueryArguments(
                query.arguments
            )
            if query.kind == .skillFile,
                !normalizedArguments.isEmpty,
                let data = try? JSONEncoder().encode(normalizedArguments),
                let json = String(data: data, encoding: .utf8)
            {
                argumentsKey = json
            } else {
                argumentsKey = ""
            }

            let key =
                "\(query.actionID.uuidString.lowercased())::\(query.kind.rawValue)::\(argumentsKey)"
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            result.append(query)
        }

        return result
    }

    private func executeActionCatalogQuery(
        _ query: KeepTalkingActionCatalogQuery,
        remoteNode: KeepTalkingNode,
        context: KeepTalkingContext?
    ) async -> KeepTalkingActionCatalogItemResult {
        do {
            let action = try await resolveLocalActionForExecution(
                actionID: query.actionID
            )
            guard
                try await isNodeAuthorizedForAction(
                    node: remoteNode,
                    action: action,
                    context: context
                )
            else {
                throw KeepTalkingClientError.actionCallNotAuthorized(
                    action: query.actionID,
                    caller: try remoteNode.requireID(),
                    context: context?.id ?? config.contextID
                )
            }

            switch query.kind {
                case .mcpTools:
                    guard case .mcpBundle = action.payload else {
                        throw KeepTalkingClientError.unsupportedActionPayload
                    }
                    let tools = try await mcpManager.listActionTools(
                        action: action
                    )
                    let projectedTools = tools.map { tool in
                        KeepTalkingActionCatalogMCPTool(
                            name: tool.name,
                            description: tool.description,
                            inputSchema: tool.inputSchema
                        )
                    }
                    return KeepTalkingActionCatalogItemResult(
                        actionID: query.actionID,
                        kind: query.kind,
                        mcpTools: projectedTools,
                        isError: false
                    )

                case .skillMetadata:
                    guard case .skill(let bundle) = action.payload else {
                        throw KeepTalkingClientError.unsupportedActionPayload
                    }
                    let metadata = try buildSkillCatalogMetadata(bundle)
                    return KeepTalkingActionCatalogItemResult(
                        actionID: query.actionID,
                        kind: query.kind,
                        skillMetadata: metadata,
                        isError: false
                    )

                case .skillFile:
                    guard case .skill(let bundle) = action.payload else {
                        throw KeepTalkingClientError.unsupportedActionPayload
                    }
                    let filePayload = try buildSkillFileCatalogPayload(
                        bundle,
                        arguments: query.arguments
                    )
                    return KeepTalkingActionCatalogItemResult(
                        actionID: query.actionID,
                        kind: query.kind,
                        skillFile: filePayload,
                        isError: false
                    )
            }
        } catch {
            return KeepTalkingActionCatalogItemResult(
                actionID: query.actionID,
                kind: query.kind,
                isError: true,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func buildSkillCatalogMetadata(
        _ bundle: KeepTalkingSkillBundle
    ) throws -> KeepTalkingActionCatalogSkillMetadata {
        try validateSkillDirectoryForCatalog(bundle.directory)
        let manifestURL = SkillDirectoryDefinitions.entryURL(
            .manifest,
            in: bundle.directory
        )
        let manifestText = try String(
            contentsOf: manifestURL,
            encoding: .utf8
        )

        return KeepTalkingActionCatalogSkillMetadata(
            name: bundle.name,
            directoryPath: bundle.directory.path,
            manifestPath: manifestURL.path,
            manifestMetadata: parseSkillManifestMetadata(manifestText),
            referencesFiles: listSkillRelativeFiles(
                in: SkillDirectoryDefinitions.entryURL(
                    .references,
                    in: bundle.directory
                ),
                root: bundle.directory
            ),
            scripts: listSkillRelativeFiles(
                in: SkillDirectoryDefinitions.entryURL(
                    .scripts,
                    in: bundle.directory
                ),
                root: bundle.directory
            ),
            assets: listSkillRelativeFiles(
                in: SkillDirectoryDefinitions.entryURL(
                    .assets,
                    in: bundle.directory
                ),
                root: bundle.directory
            ),
            manifestPreview: clippedSkillManifest(
                manifestText,
                maxCharacters: Self.actionCatalogSkillManifestMaxCharacters
            )
        )
    }

    private func buildSkillFileCatalogPayload(
        _ bundle: KeepTalkingSkillBundle,
        arguments: [String: Value]?
    ) throws -> KeepTalkingActionCatalogSkillFile {
        try validateSkillDirectoryForCatalog(bundle.directory)
        let normalizedArguments = normalizedSkillFileQueryArguments(arguments)

        let requestedPath =
            normalizedArguments["path"]?.stringValue
            ?? normalizedArguments["file"]?.stringValue
            ?? normalizedArguments["file_path"]?.stringValue
            ?? normalizedArguments["relative_path"]?.stringValue
            ?? ""
        let trimmedPath = requestedPath.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedPath.isEmpty else {
            throw SkillManagerError.invalidToolArguments(
                "Missing required `path` for skill file query."
            )
        }

        let maxCharacters = min(
            max(
                normalizedArguments["max_characters"]?.intValue
                    ?? normalizedArguments["limit"]?.intValue
                    ?? normalizedArguments["max_characters"]?.doubleValue.map { Int($0) }
                    ?? Self.actionCatalogSkillFileMaxCharacters,
                128
            ),
            Self.actionCatalogSkillFileMaxCharacters
        )

        let fileURL = try resolveSkillFileURL(
            trimmedPath,
            skillDirectory: bundle.directory
        )
        let rawData = try Data(contentsOf: fileURL)
        let fileText =
            String(data: rawData, encoding: .utf8)
            ?? String(decoding: rawData, as: UTF8.self)
        let content = clippedSkillManifest(
            fileText,
            maxCharacters: maxCharacters
        )

        let rootPath = bundle.directory.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        let relativePath: String
        if path.hasPrefix(rootPath + "/") {
            relativePath = String(path.dropFirst(rootPath.count + 1))
        } else {
            relativePath = path
        }

        return KeepTalkingActionCatalogSkillFile(
            path: relativePath,
            content: content,
            maxCharacters: maxCharacters,
            truncated: fileText.count > maxCharacters
        )
    }

    private func normalizedSkillFileQueryArguments(
        _ arguments: [String: Value]?
    ) -> [String: Value] {
        guard let arguments else {
            return [:]
        }
        if let nested = arguments["arguments"]?.objectValue {
            return nested
        }
        if let nested = arguments["params"]?.objectValue {
            return nested
        }
        return arguments
    }

    private func validateSkillDirectoryForCatalog(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else {
            throw SkillManagerError.invalidSkillDirectory(directory)
        }

        let manifestURL = SkillDirectoryDefinitions.entryURL(
            .manifest,
            in: directory
        )
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw SkillManagerError.missingSkillManifest(manifestURL)
        }
    }

    private func parseSkillManifestMetadata(
        _ manifest: String
    ) -> [String: String] {
        guard manifest.hasPrefix("---") else {
            return [:]
        }

        let lines = manifest.components(separatedBy: .newlines)
        guard
            lines.count >= 3,
            lines[0].trimmingCharacters(in: .whitespaces) == "---"
        else {
            return [:]
        }

        var metadata: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                break
            }
            guard
                let separator = line.firstIndex(of: ":"),
                separator != line.startIndex
            else {
                continue
            }

            let key = line[..<separator].trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                metadata[key] = value
            }
        }

        return metadata
    }

    private func listSkillRelativeFiles(in directory: URL, root: URL) -> [String]
    {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            return []
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        let rootPath = root.standardizedFileURL.path
        var files: [String] = []
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey]
                ),
                values.isRegularFile == true
            else {
                continue
            }

            let path = fileURL.standardizedFileURL.path
            if path.hasPrefix(rootPath + "/") {
                files.append(String(path.dropFirst(rootPath.count + 1)))
            }
        }
        return files.sorted()
    }

    private func clippedSkillManifest(
        _ text: String,
        maxCharacters: Int
    ) -> String {
        guard text.count > maxCharacters else {
            return text
        }
        return String(text.prefix(maxCharacters)) + "\n...[truncated]..."
    }
}
