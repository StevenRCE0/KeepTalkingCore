//
//  PluginHost+Actions.swift
//  KeepTalking
//
//  Bridges the KTPP host to the action system: executing a `.plugin` action
//  instance, and minting instances from Catalogue kinds. This is the seam that
//  makes plugin kinds behave like primitives — same `kt_actions` rows, same
//  grants, same call path.
//

#if os(macOS) || os(Linux)

import Foundation
import MCP

extension KeepTalkingPluginHost {

    /// What one plugin-backed action call yielded: the tool content plus the
    /// elucidation notes the plugin narrated while running (backfed into the
    /// caller's tool payload alongside `produced_resources`).
    public struct ActionCallOutput: Sendable {
        public let content: [Tool.Content]
        public let isError: Bool?
        public let elucidations: [String]
    }

    /// Executes a `.plugin` action instance — the entry point
    /// `performActionCallRequest` calls, shaped like every other manager's
    /// `callAction`.
    ///
    /// The instance's stored scope bag travels with the call (and is what an
    /// injected attestor binds), so a record says which *scoped* instance ran,
    /// not merely which kind. `manifest` (staged inputs + output slots)
    /// projects into the call's `resources` block; `runDirectory` receives the
    /// files the result carries that no requested output claimed (see
    /// `mappingGeneratedContents`).
    public func callActionDetailed(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall,
        scope: KeepTalkingActionScope,
        callerNodeID: UUID,
        contextID: UUID,
        manifest: KTResourceManifest? = nil,
        runDirectory: URL? = nil,
        onElucidation: (@Sendable (String, String?) -> Void)? = nil
    ) async throws -> ActionCallOutput {
        guard case .plugin(let bundle) = action.payload else {
            throw KTPPHostError.protocolViolation("action is not plugin-backed")
        }
        // Sub-tool gating reuses the MCP convention: `.callTool` is the class
        // wildcard, `.named(tool)` narrows to specific tools.
        let requestedTool = Self.requestedTool(in: call) ?? bundle.tool
        if let requestedTool,
            !scope.permitsNamed(requestedTool, classWildcard: .callTool)
        {
            return ActionCallOutput(
                content: [.text("Denied: tool '\(requestedTool)' is outside the granted scope.")],
                isError: true,
                elucidations: []
            )
        }

        // Instances can hold a catalog id the store has since merged away;
        // dispatch-time healing usually rewrites them, but canonicalize here
        // too so no caller can race a stale id into a session lookup.
        let catalogID = await catalogue.canonicalCatalogID(bundle.catalogID)
        let arguments: [String: Value]
        do {
            arguments = try Self.resolvingResourceURIs(
                Self.callArguments(call), manifest: manifest)
        } catch {
            return ActionCallOutput(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true, elucidations: [])
        }
        let outcome = try await callKind(
            catalogID: catalogID,
            kindName: bundle.kindName,
            tool: requestedTool,
            arguments: arguments,
            instanceID: bundle.id,
            instanceScope: bundle.scopeValue,
            contextID: contextID,
            callerNodeID: callerNodeID,
            manifest: manifest,
            onElucidation: onElucidation
        )
        return ActionCallOutput(
            content: Self.mappingResourcePaths(
                Self.mappingGeneratedContents(
                    Self.toolContent(from: outcome.content), into: manifest,
                    runDirectory: runDirectory),
                manifest: manifest),
            isError: outcome.isError,
            elucidations: outcome.elucidations
        )
    }

    /// The agent may address a sub-tool either through the proxy-tool envelope
    /// (`{tool: …, arguments: {…}}`) or by the call metadata.
    private static func requestedTool(in call: KeepTalkingActionCall) -> String? {
        if case .string(let tool)? = call.arguments["tool"], !tool.isEmpty {
            return tool
        }
        return nil
    }

    /// Unwraps the proxy envelope when present, so plugins always receive the
    /// bare argument object their `inputSchema` describes.
    private static func callArguments(_ call: KeepTalkingActionCall) -> [String: Value] {
        if case .object(let inner)? = call.arguments["arguments"] {
            return inner
        }
        return call.arguments.filter { $0.key != "tool" }
    }

    /// Tool-call IO mapped to KTRM before the call: every `kt-resource://`
    /// string in the arguments — at any depth — that names one of THIS call's
    /// resources (a staged input, or an output the caller requested) becomes
    /// that resource's path, with `/<child>` naming a file inside a collection
    /// output. The plugin and the server it wraps get resolved paths, never a
    /// handle to resolve and never a path the caller made up: a URI naming
    /// anything else refuses the call.
    static func resolvingResourceURIs(
        _ arguments: [String: Value], manifest: KTResourceManifest?
    ) throws -> [String: Value] {
        let entries = (manifest?.entries ?? []).filter { $0.path != nil }
        func resolve(_ value: Value) throws -> Value {
            switch value {
                case .string(let text):
                    guard let (handle, child) = KTResourceManifest.parseResourceURI(text) else {
                        return value
                    }
                    let entry =
                        entries.first { $0.envKey.uppercased() == handle }
                        ?? entries.first {
                            handle == "KT_\(($0.objectName ?? "").uppercased())"
                                || $0.displayName.uppercased() == handle
                        }
                    guard let entry, var path = entry.path else {
                        throw KTPPHostError.callRefused(
                            "\(text) is not one of this call's resources: request outputs on kt_run_action (otb or attachment) or pass inputs in input_handles, then use the kt-resource:// handles listed for this call."
                        )
                    }
                    if let child {
                        guard entry.isDirectory else {
                            throw KTPPHostError.callRefused(
                                "\(text) names a file inside \(entry.envKey), which is a single file, not a collection."
                            )
                        }
                        path = path.appendingPathComponent(child)
                    }
                    return .string(path.path)
                case .array(let items):
                    return .array(try items.map(resolve))
                case .object(let fields):
                    return .object(try fields.mapValues(resolve))
                default:
                    return value
            }
        }
        return try arguments.mapValues(resolve)
    }

    /// The reverse mapping on the way out: any of this call's resource paths
    /// a result's text mentions (a server reporting where it wrote a file)
    /// becomes its `kt-resource://` URI, so the caller sees KTRM, not paths.
    static func mappingResourcePaths(
        _ content: [Tool.Content], manifest: KTResourceManifest?
    ) -> [Tool.Content] {
        let entries = (manifest?.entries ?? [])
            .compactMap { entry in entry.path.map { (entry, $0.path) } }
            .sorted { $0.1.count > $1.1.count }
        guard !entries.isEmpty else { return content }
        return content.map { item in
            guard case .text(let text, let annotations, let meta) = item else { return item }
            var mapped = text
            for (entry, path) in entries where mapped.contains(path) {
                if entry.isDirectory,
                    let pattern = try? NSRegularExpression(
                        pattern: NSRegularExpression.escapedPattern(for: path) + "/([^\\s\"'/]+)")
                {
                    mapped = pattern.stringByReplacingMatches(
                        in: mapped, range: NSRange(mapped.startIndex..., in: mapped),
                        withTemplate: NSRegularExpression.escapedTemplate(
                            for: KTResourceManifest.resourceURI(handle: entry.envKey)) + "/$1")
                }
                mapped = mapped.replacingOccurrences(
                    of: path, with: KTResourceManifest.resourceURI(handle: entry.envKey))
            }
            return .text(text: mapped, annotations: annotations, _meta: meta)
        }
    }

    /// Converts the wire content array into MCP `Tool.Content`. Falls back to a
    /// rendered text block rather than losing a result to a decode mismatch.
    private static func toolContent(from value: Value) -> [Tool.Content] {
        if let data = try? JSONEncoder().encode(value),
            let decoded = try? JSONDecoder().decode([Tool.Content].self, from: data)
        {
            return decoded
        }
        if case .array(let items) = value {
            let texts: [Tool.Content] = items.compactMap { item in
                if case .object(let fields) = item,
                    case .string(let text)? = fields["text"]
                {
                    return .text(text)
                }
                return nil
            }
            if !texts.isEmpty { return texts }
        }
        if let data = try? JSONEncoder().encode(value),
            let rendered = String(data: data, encoding: .utf8)
        {
            return [.text(rendered)]
        }
        return []
    }

    // MARK: Instantiation

    /// Builds the action instance for a Catalogue kind — the template → row
    /// step, mirroring `KeepTalkingPrimitiveBundle.assigningNewID()`.
    ///
    /// Validation is intentionally shallow (declared keys only): the plugin
    /// re-enforces its own scope at call time against the stored bag every
    /// call carries.
    public func makeInstanceBundle(
        catalogID: UUID,
        kindName: String,
        name: String?,
        scope: [String: Value]?
    ) async throws -> KeepTalkingPluginBundle {
        guard let kind = await catalogue.kind(catalogID: catalogID, kindName: kindName) else {
            throw KTPPHostError.unknownKind(kindName)
        }
        var resolved = scope
        if resolved == nil, case .object(let defaults)? = kind.defaultScope {
            resolved = defaults
        }
        if let resolved, case .object(let schema)? = kind.scopeSchema {
            // `capabilities` is a RESERVED scope key (§7.5 of the resources
            // doc): the user's per-instance narrowing of the kind's declared
            // capability set — valid on every kind without being part of its
            // scopeSchema.
            let unknown = resolved.keys
                .filter { $0 != "capabilities" && schema[$0] == nil }.sorted()
            if !unknown.isEmpty {
                throw KTPPHostError.protocolViolation(
                    "scope keys not declared by '\(kindName)': \(unknown.joined(separator: ", "))")
            }
        }
        if let narrowing = resolved?["capabilities"] {
            // Shape first: a `capabilities` value that isn't a token array is
            // rejected here rather than tolerated. At call time an unreadable
            // narrowing denies (fail-closed), so accepting one at save would
            // mint an instance that silently never gets its capability.
            guard case .array(let narrowed) = narrowing else {
                throw KTPPHostError.protocolViolation(
                    "instance 'capabilities' must be an array of capability tokens")
            }
            let declared = kind.declaredCapabilities
            for entry in narrowed {
                guard case .string(let token) = entry,
                    let capability = KTPPPluginCapability(rawValue: token),
                    declared.contains(capability)
                else {
                    throw KTPPHostError.protocolViolation(
                        "instance capability narrowing may only keep capabilities "
                            + "'\(kindName)' declared; offending entry: \(entry)")
                }
            }
        }
        return KeepTalkingPluginBundle(
            name: name?.isEmpty == false ? name! : kind.displayName,
            indexDescription: kind.indexDescription,
            catalogID: catalogID,
            kindName: kindName,
            scope: resolved,
            blockingAuthorisation: kind.blockingAuthorisation ?? false
        )
    }

    /// Descriptor for a Catalogue instance. Plugins run in their own processes
    /// (KT never launches them), so this carries no sandbox-compilable verbs —
    /// it exists for display, the grant editor, remote advertisement, and (via
    /// `objects`) the file-IO seam: the kind's declared directioned objects
    /// materialize here, which is what flips `acceptsFileInput` and drives
    /// input staging / output-slot minting for calls to this instance.
    public static func descriptor(
        for bundle: KeepTalkingPluginBundle,
        kind: KTPPKindDeclaration?
    ) -> KeepTalkingActionDescriptor {
        let summary = kind?.indexDescription ?? bundle.indexDescription
        return KeepTalkingActionDescriptor(
            action: KeepTalkingActionWithDescription(
                description: summary,
                verbs: [.callTool]
            ),
            objects: kind?.objects.flatMap { declarations in
                let objects = declarations.compactMap(Self.materializedObject)
                return objects.isEmpty ? nil : objects
            }
        )
    }

    /// One declared wire object → the descriptor's `KeepTalkingActionObject`.
    /// Declarations with an unknown direction token are dropped rather than
    /// silently re-interpreted (a plugin bug must not widen file acceptance).
    private static func materializedObject(
        _ declaration: KTPPObjectDeclaration
    ) -> KeepTalkingActionObject? {
        guard
            let direction = KeepTalkingResourceDirection(rawValue: declaration.direction)
        else { return nil }
        let name = declaration.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return KeepTalkingActionObject(
            name: name,
            description: declaration.description ?? "",
            resource: .filePaths([]),
            direction: direction
        )
    }
}

#endif
