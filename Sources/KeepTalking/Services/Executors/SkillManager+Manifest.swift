import Foundation

extension SkillManager {
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

    func loadManifestContext(for directory: URL) throws
        -> SkillManifestContext
    {
        try validateSkillDirectory(directory)
        let manifestURL = SkillDirectoryDefinitions.entryURL(
            .manifest,
            in: directory
        )
        let rawManifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let manifestText = clipped(
            rawManifest,
            maxCharacters: Self.manifestMaxCharacters
        )
        let metadata = parseManifestMetadata(rawManifest)

        return SkillManifestContext(
            manifestURL: manifestURL,
            manifestText: manifestText,
            manifestMetadata: metadata,
            referencesFiles: listRelativeFiles(
                in: SkillDirectoryDefinitions.entryURL(
                    .references,
                    in: directory
                ),
                root: directory
            ),
            scripts: listRelativeFiles(
                in: SkillDirectoryDefinitions.entryURL(
                    .scripts,
                    in: directory
                ),
                root: directory
            ),
            assets: listRelativeFiles(
                in: SkillDirectoryDefinitions.entryURL(
                    .assets,
                    in: directory
                ),
                root: directory
            )
        )
    }

    func parseManifestMetadata(_ manifest: String) -> [String: String] {
        guard manifest.hasPrefix("---") else {
            return [:]
        }
        let lines = manifest.components(separatedBy: .newlines)
        guard lines.count >= 3, lines[0].trimmingCharacters(in: .whitespaces) == "---" else {
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
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
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
}
