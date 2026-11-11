//
//  CompanionLink+Actions.swift
//  KeepTalking
//
//  Plugin-backed action instances: calling one, mapping its IO to KTRM, and
//  minting instances from Catalogue kinds.
//

#if os(macOS) || os(Linux)

import Foundation
import MCP

extension KeepTalkingCompanionLink {

    public struct ActionCallOutput: Sendable {
        public let content: [Tool.Content]
        public let isError: Bool?
        public let elucidations: [String]
    }

    public func callActionDetailed(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall,
        scope: KeepTalkingActionScope,
        node: UUID,
        callerNodeID: UUID,
        contextID: UUID,
        manifest: KTResourceManifest? = nil,
        runDirectory: URL? = nil,
        actTurn: KTPPActTurn? = nil,
        onElucidation: (@Sendable (String, String?) -> Void)? = nil
    ) async throws -> ActionCallOutput {
        guard case .plugin(let bundle) = action.payload else {
            throw KTPPHostError.protocolViolation("action is not plugin-backed")
        }
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

        let catalogID = bundle.catalogID
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
            node: node,
            contextID: contextID,
            callerNodeID: callerNodeID,
            manifest: manifest,
            actTurn: actTurn,
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

    private static func requestedTool(in call: KeepTalkingActionCall) -> String? {
        if case .string(let tool)? = call.arguments["tool"], !tool.isEmpty {
            return tool
        }
        return nil
    }

    private static func callArguments(_ call: KeepTalkingActionCall) -> [String: Value] {
        if case .object(let inner)? = call.arguments["arguments"] {
            return inner
        }
        return call.arguments.filter { $0.key != "tool" }
    }

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
            let unknown = resolved.keys
                .filter { $0 != "capabilities" && schema[$0] == nil }.sorted()
            if !unknown.isEmpty {
                throw KTPPHostError.protocolViolation(
                    "scope keys not declared by '\(kindName)': \(unknown.joined(separator: ", "))")
            }
        }
        if let narrowing = resolved?["capabilities"] {
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

    static func mappingGeneratedContents(
        _ content: [Tool.Content], into manifest: KTResourceManifest?, runDirectory: URL?
    ) -> [Tool.Content] {
        var slots = (manifest?.entries ?? []).filter { $0.direction == .write && $0.path != nil }
        return content.enumerated().flatMap { index, item -> [Tool.Content] in
            guard let file = generatedFile(item, index: index) else { return [item] }
            let slotIndex =
                slots.firstIndex(where: { !$0.isDirectory }) ?? slots.firstIndex(where: \.isDirectory)
            let target: URL
            let destination: String
            if let slotIndex, let slotPath = slots[slotIndex].path {
                let slot = slots[slotIndex]
                target = slot.isDirectory ? slotPath.appendingPathComponent(file.name) : slotPath
                destination = KTResourceManifest.resourceURI(
                    handle: slot.envKey, child: slot.isDirectory ? file.name : nil)
                if !slot.isDirectory { slots.remove(at: slotIndex) }
            } else if !file.isText, let runDirectory {
                target = uniqueFile(named: file.name, in: runDirectory)
                destination = "a private resource (handle in produced_resources)"
            } else {
                return [item]
            }
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: target)
            } catch {
                return [item]
            }
            let note = Tool.Content.text(
                text: "[\(file.name) (\(file.data.count) bytes) delivered to \(destination)]",
                annotations: nil, _meta: nil)
            return file.staysInline ? [item, note] : [note]
        }
    }

    private static func generatedFile(
        _ item: Tool.Content, index: Int
    ) -> (name: String, data: Data, isText: Bool, staysInline: Bool)? {
        func named(_ stem: String, _ mimeType: String) -> String {
            MIMEType.preferredExtension(forMIMEType: mimeType).map { "\(stem).\($0)" } ?? stem
        }
        switch item {
            case .image(let base64, let mimeType, _, _):
                guard let data = decodedBase64(base64) else { return nil }
                return (named("image-\(index + 1)", mimeType), data, false, true)
            case .audio(let base64, let mimeType, _, _):
                guard let data = decodedBase64(base64) else { return nil }
                return (named("audio-\(index + 1)", mimeType), data, false, false)
            case .resource(let resource, _, _):
                let name = resourceFileName(uri: resource.uri, fallback: "resource-\(index + 1)")
                if let data = resource.blob.flatMap(decodedBase64) {
                    let isImage = resource.mimeType?.hasPrefix("image/") == true
                    return (name, data, false, isImage)
                }
                if let text = resource.text { return (name, Data(text.utf8), true, false) }
                return nil
            default:
                return nil
        }
    }

    private static func decodedBase64(_ text: String) -> Data? {
        let payload = text.range(of: ";base64,").map { String(text[$0.upperBound...]) } ?? text
        return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
    }

    private static func uniqueFile(named name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = directory.appendingPathComponent(
                ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    static func resourceFileName(uri: String, fallback: String) -> String {
        let segment = uri.split(separator: "?").first.flatMap { $0.split(separator: "/").last } ?? ""
        let safe = String(segment.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return safe.isEmpty ? fallback : String(safe.prefix(120))
    }
}

#endif
