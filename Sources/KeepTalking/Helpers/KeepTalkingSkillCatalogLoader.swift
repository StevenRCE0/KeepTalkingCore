import Foundation
import MCP

struct KeepTalkingSkillCatalogLoader {
    let manifestPreviewMaxCharacters: Int
    let filePreviewMaxCharacters: Int

    func loadContext(
        actionID: UUID,
        ownerNodeID: UUID,
        bundle: KeepTalkingSkillBundle
    ) throws -> KeepTalkingSkillCatalogContext {
        let metadata = try loadMetadata(bundle: bundle)
        return KeepTalkingSkillCatalogContext(
            actionID: actionID,
            ownerNodeID: ownerNodeID,
            bundle: bundle,
            manifestPath: metadata.manifestPath,
            manifestMetadata: metadata.manifestMetadata,
            referencesFiles: metadata.referencesFiles,
            scripts: metadata.scripts,
            assets: metadata.assets,
            manifestPreview: metadata.manifestPreview,
            loadError: nil
        )
    }

    func loadMetadata(
        bundle: KeepTalkingSkillBundle
    ) throws -> KeepTalkingActionCatalogSkillMetadata {
        try validateSkillDirectory(bundle.directory)
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
            manifestMetadata: parseManifestMetadata(manifestText),
            referencesFiles: listRelativeFiles(
                in: SkillDirectoryDefinitions.entryURL(
                    .references,
                    in: bundle.directory
                ),
                root: bundle.directory
            ),
            scripts: listRelativeFiles(
                in: SkillDirectoryDefinitions.entryURL(
                    .scripts,
                    in: bundle.directory
                ),
                root: bundle.directory
            ),
            assets: listRelativeFiles(
                in: SkillDirectoryDefinitions.entryURL(
                    .assets,
                    in: bundle.directory
                ),
                root: bundle.directory
            ),
            manifestPreview: clipped(
                manifestText,
                maxCharacters: manifestPreviewMaxCharacters
            )
        )
    }

    func loadFilePayload(
        bundle: KeepTalkingSkillBundle,
        arguments: [String: Value]?
    ) throws -> KeepTalkingActionCatalogSkillFile {
        try validateSkillDirectory(bundle.directory)
        let normalizedArguments = Self.normalizedFileArguments(arguments)

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
                    ?? normalizedArguments["max_characters"]?.doubleValue.map {
                        Int($0)
                    }
                    ?? filePreviewMaxCharacters,
                128
            ),
            filePreviewMaxCharacters
        )

        let fileURL = try resolveSkillFileURL(
            trimmedPath,
            skillDirectory: bundle.directory
        )
        let rawData = try Data(contentsOf: fileURL)
        let fileText =
            String(data: rawData, encoding: .utf8)
            ?? String(decoding: rawData, as: UTF8.self)

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
            content: clipped(fileText, maxCharacters: maxCharacters),
            maxCharacters: maxCharacters,
            truncated: fileText.count > maxCharacters
        )
    }

    static func normalizedFileArguments(
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

    func validateSkillDirectory(_ directory: URL) throws {
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

    func parseManifestMetadata(_ manifest: String) -> [String: String] {
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

    func listRelativeFiles(in directory: URL, root: URL) -> [String] {
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

    func resolveSkillFileURL(
        _ rawPath: String,
        skillDirectory: URL
    ) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SkillManagerError.invalidToolArguments(rawPath)
        }

        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else {
            candidate = skillDirectory.appendingPathComponent(trimmed)
        }

        let resolved = candidate.standardizedFileURL
        let rootPath = skillDirectory.standardizedFileURL.path
        let resolvedPath = resolved.path
        let insideRoot =
            resolvedPath == rootPath
            || resolvedPath.hasPrefix(rootPath + "/")
        guard insideRoot else {
            throw SkillManagerError.invalidSkillPath(trimmed)
        }

        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: resolvedPath,
                isDirectory: &isDirectory
            ),
            !isDirectory.boolValue
        else {
            throw SkillManagerError.invalidSkillPath(trimmed)
        }
        return resolved
    }

    func clipped(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else {
            return text
        }
        return String(text.prefix(maxCharacters)) + "\n...[truncated]..."
    }
}
