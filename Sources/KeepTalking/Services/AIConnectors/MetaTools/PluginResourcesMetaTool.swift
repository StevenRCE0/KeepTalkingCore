import Foundation
import MCP

extension KeepTalkingClient {
    /// `kt_plugin_resources`: lists the resources a local plugin action's kind
    /// declares, or reads one. Reading is the single resource exchange outside
    /// a call (`plugin.resource.read`, answered with MCP's `resources/read`
    /// contents); everything a call returns maps to KTRM at call time instead.
    /// Text comes back inline; other content is staged as an OTB, so it lives
    /// in KTRM like any produced file.
    func executePluginResourcesToolCall(
        toolCallID: String,
        rawArguments: String,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog
    ) async -> [AIMessage] {
        let functionName = Self.pluginResourcesToolFunctionName
        func reply(_ fields: [String: Any]) -> [AIMessage] {
            var payload = fields
            payload["function_name"] = functionName
            return [toolMessage(payload: jsonString(payload), toolCallID: toolCallID)]
        }
        func fail(_ code: String, _ message: String, _ extra: [String: Any] = [:]) -> [AIMessage] {
            reply(["ok": false, "error": code, "error_message": message].merging(extra) { $1 })
        }

        let args = (try? decodeToolArguments(rawArguments)) ?? [:]
        guard let token = args["action_id"]?.stringValue, !token.isEmpty else {
            return fail("missing_action_id", "Pass the plugin action's `action:` value.")
        }
        let stubs = runtimeCatalog.actionStubs.filter { $0.kind == .plugin }
        let resolution = UUIDFriendlyName.resolve(token, among: stubs.map(\.actionID))
        guard let actionID = resolution.settledID,
            let stub = stubs.first(where: { $0.actionID == actionID })
        else {
            return fail("unknown_plugin_action", "No plugin action matches '\(token)'.")
        }
        guard stub.isCurrentNode, !stub.resources.isEmpty else {
            return fail(
                "no_declared_resources",
                "\(stub.name) declares no resources readable from this node.")
        }

        #if os(macOS)
        guard
            let action = try? await KeepTalkingAction.find(actionID, on: localStore.database),
            case .plugin(let bundle) = action.payload
        else {
            return fail("unknown_plugin_action", "\(stub.name) is no longer a plugin action.")
        }
        let catalogID = await pluginHost.catalogue.canonicalCatalogID(bundle.catalogID)
        let declared = stub.resources
        let uri = args["uri"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !uri.isEmpty else {
            return reply([
                "ok": true,
                "action": stub.actionID.friendlyNameToken,
                "resources": declared.map { resource -> [String: Any] in
                    var entry: [String: Any] = ["uri": resource.uri, "name": resource.name]
                    if let description = resource.description { entry["description"] = description }
                    if let mimeType = resource.mimeType { entry["mime_type"] = mimeType }
                    if let size = resource.size { entry["size"] = size }
                    return entry
                },
            ])
        }
        guard declared.contains(where: { $0.uri == uri }) else {
            return fail(
                "undeclared_resource", "\(stub.name) does not declare '\(uri)'.",
                ["declared": declared.map(\.uri)])
        }

        let contents: [Resource.Content]
        do {
            contents = try await pluginHost.readResource(
                catalogID: catalogID, kindName: bundle.kindName, uri: uri)
        } catch {
            return fail("resource_unavailable", error.localizedDescription)
        }

        let maxCharacters = min(max(args["max_characters"]?.intValue ?? 12_000, 256), 40_000)
        var parts: [[String: Any]] = []
        for content in contents {
            var part: [String: Any] = ["uri": content.uri]
            if let mimeType = content.mimeType { part["mime_type"] = mimeType }
            if let text = content.text {
                part["text"] = clipped(text, maxCharacters: maxCharacters)
                if text.count > maxCharacters { part["truncated_from_characters"] = text.count }
            } else if let blob = content.blob, let data = Data(base64Encoded: blob) {
                let name = KeepTalkingPluginHost.resourceFileName(uri: content.uri, fallback: "resource")
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("kt-plugin-resource-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent(name)
                guard
                    (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
                    (try? data.write(to: file)) != nil,
                    let staged = await stagedFileStore.stageLocalFile(
                        at: file, filename: name, callerNodeID: config.node, consumeOnUse: false)
                else {
                    return fail("staging_unavailable", "Could not stage \(name) as an OTB.")
                }
                part["handle"] = KTResourceManifest.agentHandle(kind: .otb, id: staged.handle)
                part["name"] = name
                part["byte_count"] = data.count
            }
            parts.append(part)
        }
        return reply(["ok": true, "uri": uri, "contents": parts])
        #else
        return fail("unsupported_platform", "Plugin resources are readable on macOS only.")
        #endif
    }
}
