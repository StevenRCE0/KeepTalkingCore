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
                let dirPath = bundle.directory?.path ?? ""

                // Split parameters: path values → sandbox scopes, others → env vars
                let envParams = bundle.parameters.filter { !$0.value.hasPrefix("/") && !$0.value.isEmpty }
                let pathParams = bundle.parameters.filter { $0.value.hasPrefix("/") }

                // A path the user supplied for a kt_require_file label becomes an
                // executable file resource, so the skill can actually run a tool the
                // user pointed at (e.g. a `uv` binary outside the default exec
                // allowlist). Directory-granted paths stay read-only scopes.
                let fileGranted =
                    pathParams
                    .filter { bundle.requiredFiles.contains($0.key) }
                    .map { URL(fileURLWithPath: $0.value) }
                let dirParams =
                    pathParams
                    .filter { !bundle.requiredFiles.contains($0.key) }
                    .reduce(into: [String: URL]()) { $0[$1.key] = URL(fileURLWithPath: $1.value) }

                let fileResources: [URL] = (bundle.directory.map { [$0] } ?? []) + fileGranted

                return KeepTalkingActionDescriptor(
                    subject: KeepTalkingActionResourceWithDescription(
                        description: bundle.name,
                        resource: .command([[dirPath]])
                    ),
                    action: KeepTalkingActionWithDescription(
                        description: "skill execution",
                        verbs: [.read, .execute]
                    ),
                    object: KeepTalkingActionResourceWithDescription(
                        description: dirPath,
                        resource: .filePaths(fileResources)
                    ),
                    environment: envParams.isEmpty ? nil : envParams,
                    directories: dirParams.isEmpty ? nil : dirParams
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
                return filesystemDescriptor(for: bundle, scope: .all)

            case .acp, .primitive, .semanticRetrieval, .actionCreation, .plugin:
                // ACP agents run UNsandboxed by design — containment is advisory
                // (the session cwd + advertised fs caps), not enforced — so there
                // is no implicit sandbox descriptor, just like primitives, which
                // spawn no confined subprocess. Plugins likewise: KT never
                // launches them, so it has nothing to confine.
                return nil
        }
    }

    /// Derives a descriptor for a filesystem bundle, filtered by a grant scope.
    ///
    /// The scope determines which verbs are included — e.g. a read-only scope
    /// produces only `[.read, .ls, .grep]` verbs. `.all` yields the bundle's full
    /// filesystem capability; per-grant narrowing also happens later in
    /// `resolvedDescriptor(callerScope:)`, so this is normally called with `.all`.
    public static func filesystemDescriptor(
        for bundle: KeepTalkingFilesystemBundle,
        scope: KeepTalkingActionScope
    ) -> KeepTalkingActionDescriptor? {
        let rootPath = bundle.rootPath
        guard !rootPath.isEmpty else { return nil }
        let rootURL = URL(fileURLWithPath: rootPath)

        var verbs: Set<KeepTalkingActionVerb> = []
        if scope.allows(.read) {
            verbs.formUnion([.read, .ls, .grep])
        }
        if scope.allows(.ls) {
            verbs.insert(.ls)
        }
        if scope.allows(.grep) {
            verbs.insert(.grep)
        }
        if scope.allows(.write) {
            verbs.insert(.write)
        }
        if scope.allows(.execute) {
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
        additionalGrants: [KeepTalkingActionGrant] = [],
        callerScope: KeepTalkingActionScope = .all
    ) -> KeepTalkingActionDescriptor {
        // Start with the action's explicit descriptor, fall back to implicit
        let base =
            action.descriptor
            ?? implicitDescriptor(for: action)
            ?? KeepTalkingActionDescriptor()

        // No grants and an unrestricted caller → nothing to merge or narrow.
        if additionalGrants.isEmpty, case .all = callerScope { return base }

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

        // A `.verbs` grant scope NARROWS the action's capability (never widens):
        // intersect the merged structural verbs with what the caller was granted.
        // Descriptors never carry `.named` tokens, so the intersection cleanly
        // drops any op class the caller wasn't granted. `.all` leaves verbs as-is.
        if case .verbs(let granted) = callerScope {
            mergedVerbs.formIntersection(granted)
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
            },
            // NOTE: `objects` (directioned file objects) are intentionally NOT
            // forwarded here. `hasSandboxConstraints` counts a non-empty `objects`
            // as a constraint, but `compileProfile` emits no grants for it — so
            // forwarding it without the matching grant path would sandbox an action
            // and then deny its own declared files. Forward it together with that
            // grant logic when directioned objects are actually populated.
            environment: base.environment,
            directories: base.directories,
            directoryDirections: base.directoryDirections
        )
    }

    /// Resolves the final sandbox policy for an action, merging its descriptor
    /// with any additional grants and compiling via the provided sandbox backend.
    public static func resolvedPolicy(
        for action: KeepTalkingAction,
        additionalGrants: [KeepTalkingActionGrant] = [],
        callerScope: KeepTalkingActionScope = .all,
        sandbox: any ProcessSandboxing
    ) throws -> KTSandboxPolicy {
        let descriptor = resolvedDescriptor(
            for: action,
            additionalGrants: additionalGrants,
            callerScope: callerScope
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
