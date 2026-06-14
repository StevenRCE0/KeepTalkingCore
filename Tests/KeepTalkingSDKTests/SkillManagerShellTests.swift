import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

/// Exercises the agent-facing `kt_shell` tool interface end-to-end (real
/// subprocess exec, NO LLM/agent loop): the tool surface `makeSkillTools`
/// advertises, the `executeShellCommand` handler, the `executeSkillToolCalls`
/// dispatch the agent's tool calls flow through, manifest env injection +
/// expansion, path scrubbing, workspace cwd, and exec under the seatbelt sandbox.
struct SkillManagerShellTests {

    // MARK: - Helpers

    private func makeManager(timeout: TimeInterval = 15) -> SkillManager {
        SkillManager(
            nodeConfig: KeepTalkingConfig(contextID: UUID(), node: UUID()),
            aiConnector: nil,
            scriptTimeoutSeconds: timeout
        )
    }

    private func makeFixtureDirectory() throws -> URL {
        // Resolve symlinks so the path the sandbox profile grants (standardized)
        // matches the canonical path seatbelt evaluates against (/var → /private/var).
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath()
    }

    private func toolText(_ message: AIMessage?) -> String? {
        if case .text(let value)? = message?.content { return value }
        return nil
    }

    // MARK: - Tool surface

    @Test("kt_shell is advertised to the agent when execution is available")
    func shellToolIsExposed() async throws {
        let manager = makeManager()
        let context = SkillManifestContext(
            manifestText: "", manifestMetadata: [:], referencesFiles: [],
            scripts: [], assets: [])
        let tools = await manager.makeSkillTools(context: context)
        #expect(tools.contains { $0.functionName == SkillManager.shellToolName })
    }

    // MARK: - Execution

    @Test("kt_shell runs a command and reports stdout + exit code")
    func shellRunsCommand() async throws {
        let workspace = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = makeManager()

        let block = try await manager.executeShellCommand(
            ["command": .string("echo hello-shell")],
            actionID: UUID(), skillDirectory: nil, workspaceDirectory: workspace)

        #expect(block.contains("exit_code: 0"))
        #expect(block.contains("hello-shell"))
    }

    @Test("kt_shell is a real shell: pipes and redirection work")
    func shellSupportsPipesAndRedirection() async throws {
        let workspace = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = makeManager()

        let piped = try await manager.executeShellCommand(
            ["command": .string("echo hi | tr 'a-z' 'A-Z'")],
            actionID: UUID(), skillDirectory: nil, workspaceDirectory: workspace)
        #expect(piped.contains("HI"))

        let redirected = try await manager.executeShellCommand(
            ["command": .string("printf 'piped' > out.txt && cat out.txt")],
            actionID: UUID(), skillDirectory: nil, workspaceDirectory: workspace)
        #expect(redirected.contains("piped"))
        #expect(redirected.contains("exit_code: 0"))
    }

    @Test("kt_shell uses the thread workspace as its working directory")
    func shellUsesWorkspaceAsCwd() async throws {
        let workspace = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = makeManager()

        let block = try await manager.executeShellCommand(
            ["command": .string("printf 'CWD-OK' > probe.txt")],
            actionID: UUID(), skillDirectory: nil, workspaceDirectory: workspace)
        #expect(block.contains("exit_code: 0"))

        let probe = workspace.appendingPathComponent("probe.txt")
        #expect(FileManager.default.fileExists(atPath: probe.path))
        #expect((try? String(contentsOf: probe, encoding: .utf8)) == "CWD-OK")
    }

    @Test("kt_shell expands a manifest resource handle to the real path")
    func shellExpandsManifestHandle() async throws {
        let workspace = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = makeManager()

        let resource = workspace.appendingPathComponent("note.txt")
        try "MANIFEST-RESOURCE-BODY".write(to: resource, atomically: true, encoding: .utf8)
        let manifest = KTResourceManifest.build(
            grantedCandidates: [
                .init(
                    kind: .attachment, id: UUID(), path: resource,
                    direction: .read, displayName: "note.txt", isDirectory: false)
            ],
            umbrellaAttachmentsDir: nil)
        let key = try #require(manifest.entries.first?.envKey)

        // The shell — not KeepTalking — expands $KEY to the injected path, so the
        // file content is what reaches stdout.
        let block = try await manager.executeShellCommand(
            ["command": .string("cat \"$\(key)\"")],
            actionID: UUID(), skillDirectory: nil,
            manifest: manifest, workspaceDirectory: workspace)
        #expect(block.contains("MANIFEST-RESOURCE-BODY"))
        #expect(block.contains("exit_code: 0"))
    }

    @Test("kt_shell scrubs the absolute resource path back to its handle")
    func shellSanitizesAbsolutePaths() async throws {
        let workspace = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = makeManager()

        let resource = workspace.appendingPathComponent("secret-location.txt")
        try "x".write(to: resource, atomically: true, encoding: .utf8)
        let manifest = KTResourceManifest.build(
            grantedCandidates: [
                .init(
                    kind: .otb, id: UUID(), path: resource,
                    direction: .read, displayName: "secret-location.txt",
                    isDirectory: false)
            ],
            umbrellaAttachmentsDir: nil)
        let key = try #require(manifest.entries.first?.envKey)
        let canonicalPath = try #require(manifest.entries.first?.path?.path)

        // echo prints the real (canonical) path; the result block must show the
        // $KEY handle instead, never the staging location.
        let block = try await manager.executeShellCommand(
            ["command": .string("printf '%s' \"$\(key)\"")],
            actionID: UUID(), skillDirectory: nil,
            manifest: manifest, workspaceDirectory: workspace)
        #expect(block.contains("$\(key)"))
        // The stdout section must not leak the raw absolute path.
        let stdoutSection = block.components(separatedBy: "stdout:").last ?? ""
        #expect(!stdoutSection.contains(canonicalPath))
    }

    @Test("kt_shell rejects an empty command")
    func shellRejectsEmptyCommand() async throws {
        let manager = makeManager()
        await #expect(throws: SkillManagerError.self) {
            _ = try await manager.executeShellCommand(
                ["command": .string("   ")],
                actionID: UUID(), skillDirectory: nil)
        }
    }

    // MARK: - Tool-call dispatch (the path the agent's tool calls flow through)

    @Test("a kt_shell tool call routes through executeSkillToolCalls")
    func shellRoutesThroughToolCallDispatch() async throws {
        let workspace = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = makeManager()

        let context = SkillManifestContext(
            manifestText: "", manifestMetadata: [:],
            referencesFiles: [], scripts: [], assets: [])
        let toolCall = AIToolCall(
            id: "call-1", name: SkillManager.shellToolName,
            argumentsJSON: "{\"command\":\"echo routed-ok\"}")

        let messages = try await manager.executeSkillToolCalls(
            [toolCall], actionID: UUID(), skillDirectory: nil,
            manifestContext: context, sandboxPolicy: nil, scriptTrace: nil,
            attachmentsDir: nil, manifest: nil, workspaceDirectory: workspace)

        #expect(messages.count == 1)
        #expect(messages.first?.role == .tool)
        let payload = try #require(toolText(messages.first))
        #expect(payload.contains("routed-ok"))
        #expect(payload.contains("exit_code: 0"))
    }

    // MARK: - Sandboxed exec

    @Test("kt_shell can exec system tools under the seatbelt sandbox")
    func shellExecsSystemToolsUnderSandbox() async throws {
        let workspace = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = makeManager()

        let granted = workspace.appendingPathComponent("sbx.txt")
        try "SANDBOXED-OK".write(to: granted, atomically: true, encoding: .utf8)

        // execute + read verbs, workspace granted read/write. Compiling the policy
        // proves the broadened interpreter/system-bin exec grants let /bin/cat run.
        let descriptor = KeepTalkingActionDescriptor(
            action: KeepTalkingActionWithDescription(
                description: "", verbs: [.execute, .read, .ls]),
            directories: ["work": workspace],
            directoryDirections: ["work": .inputOutput])
        let policy = try SeatbeltSandbox().compilePolicy(descriptor: descriptor)

        // `$WORK` is injected by the sandbox from the directory label.
        let block = try await manager.executeShellCommand(
            ["command": .string("cat \"$WORK/sbx.txt\"")],
            actionID: UUID(), skillDirectory: nil,
            sandboxPolicy: policy, workspaceDirectory: workspace)
        #expect(block.contains("SANDBOXED-OK"))
        #expect(block.contains("exit_code: 0"))
    }
}
