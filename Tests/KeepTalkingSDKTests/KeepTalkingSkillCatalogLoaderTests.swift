import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

struct KeepTalkingSkillCatalogLoaderTests {
    @Test("skill catalog loader reads manifest metadata and indexed files")
    func loadsMetadata() throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let bundle = try makeSkillBundle(
            in: fixture,
            manifest: """
                ---
                name: fixture-skill
                description: Fixture description
                ---
                # Fixture Skill
                """
        )

        let loader = KeepTalkingSkillCatalogLoader(
            manifestPreviewMaxCharacters: 512,
            filePreviewMaxCharacters: 64
        )
        let metadata = try loader.loadMetadata(bundle: bundle)

        #expect(metadata.name == "fixture-skill")
        #expect(metadata.manifestMetadata["name"] == "fixture-skill")
        #expect(metadata.manifestMetadata["description"] == "Fixture description")
        #expect(metadata.referencesFiles == ["references/guide.md"])
        #expect(metadata.scripts == ["scripts/run.sh"])
        #expect(metadata.assets == ["assets/info.txt"])
        #expect(metadata.manifestPreview.contains("# Fixture Skill"))
    }

    @Test("skill catalog loader reads nested file arguments and truncates content")
    func loadsFilePayloadFromNestedArguments() throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let referenceContent = String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 8)
        let bundle = try makeSkillBundle(
            in: fixture,
            referenceContent: referenceContent
        )

        let loader = KeepTalkingSkillCatalogLoader(
            manifestPreviewMaxCharacters: 512,
            filePreviewMaxCharacters: 32
        )
        let payload = try loader.loadFilePayload(
            bundle: bundle,
            arguments: [
                "params": .object([
                    "path": .string("references/guide.md"),
                    "max_characters": .int(8),
                ])
            ]
        )

        #expect(payload.path == "references/guide.md")
        #expect(payload.maxCharacters == 32)
        #expect(payload.truncated == true)
        #expect(
            payload.content
                == String(referenceContent.prefix(32)) + "\n...[truncated]..."
        )
    }

    @Test("skill catalog loader rejects file paths outside the skill directory")
    func rejectsEscapedPaths() throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let bundle = try makeSkillBundle(in: fixture)
        let loader = KeepTalkingSkillCatalogLoader(
            manifestPreviewMaxCharacters: 512,
            filePreviewMaxCharacters: 64
        )

        #expect(throws: SkillManagerError.self) {
            _ = try loader.resolveSkillFileURL(
                "../outside.txt",
                skillDirectory: bundle.directory
            )
        }
    }

    private func makeSkillBundle(
        in root: URL,
        manifest: String = """
            ---
            name: fixture-skill
            description: Fixture description
            ---
            # Fixture Skill
            """,
        referenceContent: String = "reference content",
        scriptContent: String = "#!/bin/zsh\nprint 'hello'\n",
        assetContent: String = "asset content"
    ) throws -> KeepTalkingSkillBundle {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let manifestURL = SkillDirectoryDefinitions.entryURL(.manifest, in: root)
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        let referencesDirectory = SkillDirectoryDefinitions.entryURL(
            .references,
            in: root
        )
        try FileManager.default.createDirectory(
            at: referencesDirectory,
            withIntermediateDirectories: true
        )
        try referenceContent.write(
            to: referencesDirectory.appendingPathComponent("guide.md"),
            atomically: true,
            encoding: .utf8
        )

        let scriptsDirectory = SkillDirectoryDefinitions.entryURL(
            .scripts,
            in: root
        )
        try FileManager.default.createDirectory(
            at: scriptsDirectory,
            withIntermediateDirectories: true
        )
        try scriptContent.write(
            to: scriptsDirectory.appendingPathComponent("run.sh"),
            atomically: true,
            encoding: .utf8
        )

        let assetsDirectory = SkillDirectoryDefinitions.entryURL(.assets, in: root)
        try FileManager.default.createDirectory(
            at: assetsDirectory,
            withIntermediateDirectories: true
        )
        try assetContent.write(
            to: assetsDirectory.appendingPathComponent("info.txt"),
            atomically: true,
            encoding: .utf8
        )

        return KeepTalkingSkillBundle(
            name: "fixture-skill",
            indexDescription: "Fixture skill",
            directory: root
        )
    }

    private func makeFixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
