#if os(macOS)
import Foundation

/// Derives sandbox-relevant descriptors from action payloads and merges them
/// with dynamically granted scopes to produce a final sandbox policy.
public enum ScopeResolver {

    /// Derives an implicit descriptor from an action's payload type.
    ///
    /// The returned descriptor captures the minimum verbs and object scope
    /// required for the action to function. Returns `nil` for action types
    /// that don't spawn subprocesses (primitives, semantic retrieval).
    public static func implicitDescriptor(
        for action: KeepTalkingAction
    ) -> KeepTalkingActionDescriptor? {
        switch action.payload {
        case .skill(let bundle):
            return KeepTalkingActionDescriptor(
                subject: KeepTalkingActionResourceWithDescription(
                    description: bundle.name,
                    resource: .command([[bundle.directory.path]])
                ),
                action: KeepTalkingActionWithDescription(
                    description: "skill execution",
                    verbs: [.read, .execute]
                ),
                object: KeepTalkingActionResourceWithDescription(
                    description: bundle.directory.path,
                    resource: .filePaths([bundle.directory])
                )
            )

        case .mcpBundle(let bundle):
            switch bundle.service {
            case .stdio(let arguments, _):
                return KeepTalkingActionDescriptor(
                    subject: KeepTalkingActionResourceWithDescription(
                        description: bundle.name,
                        resource: .command([arguments])
                    ),
                    action: KeepTalkingActionWithDescription(
                        description: "MCP stdio",
                        verbs: [.execute]
                    ),
                    object: KeepTalkingActionResourceWithDescription(
                        description: arguments.first ?? "process",
                        resource: .command([arguments])
                    )
                )

            case .http(let url, _, _, _):
                return KeepTalkingActionDescriptor(
                    subject: KeepTalkingActionResourceWithDescription(
                        description: bundle.name,
                        resource: .urls([url])
                    ),
                    action: KeepTalkingActionWithDescription(
                        description: "MCP HTTP",
                        verbs: [.network, .callTool]
                    ),
                    object: KeepTalkingActionResourceWithDescription(
                        description: url.absoluteString,
                        resource: .urls([url])
                    )
                )
            }

        case .filesystem(let bundle):
            return filesystemDescriptor(for: bundle, mask: .all)

        case .primitive, .semanticRetrieval:
            return nil
        }
    }

    /// Derives a descriptor for a filesystem bundle, filtered by a permission mask.
    ///
    /// The mask determines which verbs are included — e.g. a read-only mask
    /// produces only `[.read, .ls, .grep]` verbs.
    public static func filesystemDescriptor(
        for bundle: KeepTalkingFilesystemBundle,
        mask: KeepTalkingActionPermissionMask
    ) -> KeepTalkingActionDescriptor? {
        guard let rootPath = bundle.rootPath else { return nil }
        let rootURL = URL(fileURLWithPath: rootPath)

        var verbs: Set<KeepTalkingActionVerb> = []
        if mask.contains(.read) {
            verbs.formUnion([.read, .ls, .grep])
        }
        if mask.contains(.write) {
            verbs.insert(.write)
        }
        if mask.contains(.execute) {
            verbs.insert(.execute)
        }

        guard !verbs.isEmpty else { return nil }

        return KeepTalkingActionDescriptor(
            action: KeepTalkingActionWithDescription(
                description: "filesystem",
                verbs: verbs
            ),
            object: KeepTalkingActionResourceWithDescription(
                description: rootPath,
                resource: .filePaths([rootURL])
            )
        )
    }

    /// Merges an action's implicit descriptor with additional granted descriptors.
    ///
    /// The merge takes the union of verbs and the union of object resources
    /// from all descriptors. The subject from the action's own descriptor is preserved.
    public static func resolvedDescriptor(
        for action: KeepTalkingAction,
        additionalGrants: [KeepTalkingActionGrant] = []
    ) -> KeepTalkingActionDescriptor {
        // Start with the action's explicit descriptor, fall back to implicit
        let base = action.descriptor
            ?? implicitDescriptor(for: action)
            ?? KeepTalkingActionDescriptor()

        guard !additionalGrants.isEmpty else { return base }

        var mergedVerbs = base.action?.verbs ?? []
        var mergedFilePaths: [URL] = []
        var mergedURLs: [URL] = []
        var mergedCommands: [[String]] = []

        // Collect base object resources
        collectResources(
            from: base.object?.resource,
            filePaths: &mergedFilePaths,
            urls: &mergedURLs,
            commands: &mergedCommands
        )

        // Merge each grant
        for grant in additionalGrants {
            if let grantVerbs = grant.descriptor.action?.verbs {
                mergedVerbs.formUnion(grantVerbs)
            }
            collectResources(
                from: grant.descriptor.object?.resource,
                filePaths: &mergedFilePaths,
                urls: &mergedURLs,
                commands: &mergedCommands
            )
        }

        // Build the merged object resource — prefer the most common type
        let mergedObject: KeepTalkingActionResource?
        if !mergedFilePaths.isEmpty {
            mergedObject = .filePaths(mergedFilePaths)
        } else if !mergedURLs.isEmpty {
            mergedObject = .urls(mergedURLs)
        } else if !mergedCommands.isEmpty {
            mergedObject = .command(mergedCommands)
        } else {
            mergedObject = base.object?.resource
        }

        return KeepTalkingActionDescriptor(
            subject: base.subject,
            action: KeepTalkingActionWithDescription(
                description: base.action?.description ?? "",
                verbs: mergedVerbs.isEmpty ? nil : mergedVerbs
            ),
            object: mergedObject.map {
                KeepTalkingActionResourceWithDescription(
                    description: base.object?.description ?? "",
                    resource: $0
                )
            }
        )
    }

    /// Resolves the final sandbox policy for an action, merging its descriptor
    /// with any additional grants and compiling via the provided sandbox backend.
    public static func resolvedPolicy(
        for action: KeepTalkingAction,
        additionalGrants: [KeepTalkingActionGrant] = [],
        sandbox: any ProcessSandboxing
    ) throws -> KTSandboxPolicy {
        let descriptor = resolvedDescriptor(
            for: action,
            additionalGrants: additionalGrants
        )
        return try sandbox.compilePolicy(descriptor: descriptor)
    }

    // MARK: - Private

    private static func collectResources(
        from resource: KeepTalkingActionResource?,
        filePaths: inout [URL],
        urls: inout [URL],
        commands: inout [[String]]
    ) {
        guard let resource else { return }
        switch resource {
        case .filePaths(let paths):
            for path in paths where !filePaths.contains(path) {
                filePaths.append(path)
            }
        case .urls(let u):
            for url in u where !urls.contains(url) {
                urls.append(url)
            }
        case .command(let cmds):
            commands.append(contentsOf: cmds)
        }
    }
}
#endif
