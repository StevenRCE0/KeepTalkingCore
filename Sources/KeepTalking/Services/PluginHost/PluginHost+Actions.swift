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

    /// Executes a `.plugin` action instance — the entry point
    /// `performActionCallRequest` calls, shaped like every other manager's
    /// `callAction`.
    ///
    /// The instance's stored scope bag is what gets bound into the signed
    /// authorization, so the receipt records which *scoped* instance ran, not
    /// merely which kind.
    public func callAction(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall,
        scope: KeepTalkingActionScope,
        callerNodeID: UUID,
        contextID: UUID
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        guard case .plugin(let bundle) = action.payload else {
            throw KTPPHostError.protocolViolation("action is not plugin-backed")
        }
        // Sub-tool gating reuses the MCP convention: `.callTool` is the class
        // wildcard, `.named(tool)` narrows to specific tools.
        let requestedTool = Self.requestedTool(in: call) ?? bundle.tool
        if let requestedTool,
            !scope.permitsNamed(requestedTool, classWildcard: .callTool)
        {
            return (
                content: [.text("Denied: tool '\(requestedTool)' is outside the granted scope.")],
                isError: true
            )
        }

        let outcome = try await callKind(
            catalogID: bundle.catalogID,
            kindName: bundle.kindName,
            tool: requestedTool,
            arguments: Self.callArguments(call),
            instanceID: bundle.id,
            instanceScope: bundle.scopeValue,
            contextID: contextID,
            callerNodeID: callerNodeID
        )
        return (content: Self.toolContent(from: outcome.content), isError: outcome.isError)
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
    /// re-enforces its own scope at call time, and the signed authorization
    /// binds whatever bag ends up stored, so a wrong value can never be
    /// silently swapped for a different one later.
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
            let unknown = resolved.keys.filter { schema[$0] == nil }.sorted()
            if !unknown.isEmpty {
                throw KTPPHostError.protocolViolation(
                    "scope keys not declared by '\(kindName)': \(unknown.joined(separator: ", "))")
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
    /// it exists for display, the grant editor, and remote advertisement.
    public static func descriptor(
        for bundle: KeepTalkingPluginBundle,
        kind: KTPPKindDeclaration?
    ) -> KeepTalkingActionDescriptor {
        let summary = kind?.indexDescription ?? bundle.indexDescription
        return KeepTalkingActionDescriptor(
            action: KeepTalkingActionWithDescription(
                description: summary,
                verbs: [.callTool]
            )
        )
    }
}

#endif
