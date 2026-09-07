import AIProxy
import Foundation
import Testing

@testable import KeepTalkingSDK

/// Produced resources as the agent experiences them, across every producer.
///
/// On 2026-09-07 a photo requested from the phone arrived, was materialized to
/// disk, and was still reported as impossible to inspect: the agent held a
/// handle (`KT_OTB_DOWNY_CLEAR_STINGRAY`) but neither the automatic next-turn
/// injection nor the read tool could turn it back into bytes. The handle is a
/// word code over a hash, and both paths resolved it with the candidate-less
/// parser that only understands the retired hex form.
///
/// Every producer here is driven the way the model drives it, and each result
/// is checked at both consumption seams: the bytes must land in the next turn
/// unasked, AND the handle must read back through the tool in a later turn.
struct ProducedResourceAgentSurfaceTests {

    // MARK: - Filesystem action

    @Test("a get-file OTB is injected next turn and reads back by handle")
    func filesystemOTB() async throws {
        try await AgentSurface.withFilesystem { surface, fs in
            try fs.seed("report.txt", text: "needle from the filesystem")

            let reply = try await fs.call("get-file", ["path": "report.txt"])
            let handle = try reply.onlyHandle()
            #expect(handle.kind == "otb")

            try await expectConsumable(
                handle, after: reply, on: surface, needle: "needle from the filesystem")
        }
    }

    @Test("a get-file attachment is injected next turn and reads back by handle")
    func filesystemAttachment() async throws {
        try await AgentSurface.withFilesystem { surface, fs in
            try fs.seed("report.txt", text: "needle kept as an attachment")

            let reply = try await fs.call(
                "get-file", ["path": "report.txt"], outputPersistence: .attachment)
            let handle = try reply.onlyHandle()
            #expect(handle.kind == "attachment")
            #expect(handle.handle.hasPrefix("KT_ATTACHMENT_"))

            try await expectConsumable(
                handle, after: reply, on: surface, needle: "needle kept as an attachment")
        }
    }

    // MARK: - ask-for-file primitive

    @Test("a picked file from ask-for-file is injected next turn and reads back by handle")
    func askForFile() async throws {
        let picked = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-\(UUID()).txt")
        try Data("needle picked on the phone".utf8).write(to: picked)
        defer { try? FileManager.default.removeItem(at: picked) }

        // The picker the phone would show, answering with the file it chose.
        let registry = KeepTalkingPrimitiveRegistry(
            toolParameters: { _ in ["type": AIProxyJSONValue.string("object")] },
            callAction: { _, _, _ in
                KeepTalkingPrimitiveActionResponse(
                    text: "Picked 1 file.",
                    outputFiles: [
                        KeepTalkingLocalAttachmentInput(
                            sourceURL: picked, filename: "IMG_4021.txt")
                    ])
            })
        try await AgentSurface.with(primitiveRegistry: registry) { surface in
            let actionID = try await surface.mountPrimitive(
                KeepTalkingPrimitiveBundle(
                    name: "Request File From Phone",
                    indexDescription: "Prompts the phone user to select a file.",
                    action: .askForFile))

            let reply = try await surface.call(
                actionID: actionID, source: .primitive, operation: "ask-for-file",
                arguments: [:])
            let handle = try reply.onlyHandle()
            #expect(handle.kind == "otb")
            #expect(handle.name == "IMG_4021.txt")

            try await expectConsumable(
                handle, after: reply, on: surface, needle: "needle picked on the phone")
        }
    }

    // MARK: - Skill I/O

    #if os(macOS)
    @Test("a skill reads its input handle and its output is injected next turn and reads back")
    func skillInputAndOutput() async throws {
        // The inner model does the one thing a skill run needs: copy the read
        // slot it was given to the write slot it was given, then stop.
        let model = ScriptedSkillModel { read, write in
            "cat \"$\(read ?? "MISSING_INPUT")\" > \"$\(write)\""
        }
        try await AgentSurface.withFilesystem(aiConnector: model) { surface, fs in
            try fs.seed("input.txt", text: "needle passed through a skill")
            try writeSkillManifest(in: fs.root)
            let skillID = try await surface.mountSkill(
                KeepTalkingSkillBundle(
                    name: "copy-skill", indexDescription: "Copies its input.",
                    directory: fs.root.resolvingSymlinksInPath()))

            // The agent first pulls the file (an OTB), then feeds that handle in.
            let fetched = try await fs.call("get-file", ["path": "input.txt"])
            let input = try #require(await surface.stagedID(of: try fetched.onlyHandle()))

            let reply = try await surface.call(
                actionID: skillID, source: .skill, operation: "copy-skill",
                arguments: ["task": "copy the input"],
                inputHandles: [input],
                outputPersistence: .otb, outputName: "copy")
            #expect(reply.ok, Comment(rawValue: reply.errorMessage + reply.text))
            let handle = try reply.onlyHandle()
            #expect(handle.kind == "otb")

            try await expectConsumable(
                handle, after: reply, on: surface, needle: "needle passed through a skill")
        }
    }
    #endif

    // MARK: - When the handle cannot be served

    @Test("an expired OTB says it expired, not that the attachment is missing")
    func expiredOTB() async throws {
        try await AgentSurface.withFilesystem { surface, fs in
            try fs.seed("report.txt", text: "gone soon")
            let reply = try await fs.call("get-file", ["path": "report.txt"])
            let handle = try reply.onlyHandle()

            // What the TTL reaper does to it ten minutes later.
            let id = try #require(await surface.stagedID(of: handle))
            await surface.client.stagedFileStore.discard(handle: id)

            let read = try await surface.read(handle.handle, mode: "native")
            #expect(!read.ok)
            #expect(read.error == "otb_unavailable")
            #expect(read.payload["ttl_seconds"] as? Int == 600)
            #expect(read.errorMessage.contains("expired"))
            #expect(read.native == nil)
        }
    }

    @Test("another peer's OTB handle is refused as foreign, not reported missing")
    func foreignOTB() async throws {
        try await AgentSurface.withFilesystem { surface, fs in
            // A blob some other node staged here for itself; its handle leaked.
            let otherNode = UUID()
            let leaked = UUID()
            let file = try fs.seed("theirs.txt", text: "not for this peer")
            await surface.client.stagedFileStore.register(
                handle: leaked, url: file, callerNodeID: otherNode,
                filename: "theirs.txt", byteCount: 17)
            let handle = KTResourceManifest.agentHandle(kind: .otb, id: leaked)

            let read = try await surface.read(handle, mode: "native")
            #expect(!read.ok)
            #expect(read.error == "otb_foreign_handle")
            #expect(read.payload["owner_node"] as? String == otherNode.uuidString.lowercased())
            #expect(read.native == nil)
        }
    }

    @Test("a filename is refused as not a handle")
    func filenameIsNotAHandle() async throws {
        try await AgentSurface.withFilesystem { surface, _ in
            let read = try await surface.read("report.txt", mode: "metadata")
            #expect(!read.ok)
            #expect(read.error == "invalid_handle")
        }
    }

    // MARK: - The two seams

    /// The two ways a produced resource must reach the model: unasked at the
    /// top of the next turn, and by handle through the read tool later.
    private func expectConsumable(
        _ handle: KTResourceManifest.AgentResource,
        after reply: AgentReply,
        on surface: AgentSurface,
        needle: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let injected = await surface.nextTurnInjection(after: reply)
        #expect(
            injected.count == 1, "expected the resource injected once, got \(injected.count)",
            sourceLocation: sourceLocation)
        let injectedText = injected.first?.content?.text ?? ""
        #expect(injectedText.contains(handle.handle), sourceLocation: sourceLocation)
        #expect(injectedText.contains(needle), sourceLocation: sourceLocation)

        let metadata = try await surface.read(handle.handle, mode: "metadata")
        #expect(
            metadata.ok, "metadata read failed: \(metadata.error) \(metadata.errorMessage)",
            sourceLocation: sourceLocation)

        let native = try await surface.read(handle.handle, mode: "native")
        #expect(
            native.ok, "native read failed: \(native.error) \(native.errorMessage)",
            sourceLocation: sourceLocation)
        #expect(
            native.native?.content?.text.contains(needle) == true,
            "native read did not carry the file's content",
            sourceLocation: sourceLocation)
    }

    // MARK: - Skill fixtures

    /// The smallest skill there is: a SKILL.md and nothing else. The skill's
    /// own directory doubles as the filesystem root the test seeds.
    private func writeSkillManifest(in root: URL) throws {
        try """
        ---
        name: copy-skill
        description: Copies its input file to its output slot.
        ---
        # Copy Skill
        """.write(
            to: SkillDirectoryDefinitions.entryURL(.manifest, in: root),
            atomically: true, encoding: .utf8)
    }

    /// The model inside a skill run, scripted: one `kt_shell` call built from
    /// the read and write slots the resources block advertised, then a final
    /// answer. It finds the slots the same way a real model is told to — from
    /// the `$KT_<KIND>_<WORDS>  file  "<name>"  read|write` lines.
    private actor ScriptedSkillModel: AIConnector {
        nonisolated let capabilities = AIConnectorCapabilities(
            supportsNativeToolCalling: true)
        private let command: @Sendable (_ readSlot: String?, _ writeSlot: String) -> String
        private var turns = 0

        init(command: @escaping @Sendable (String?, String) -> String) {
            self.command = command
        }

        func completeTurn(
            messages: [AIMessage],
            tools: [KeepTalkingActionToolDefinition],
            model: String,
            toolChoice: AIToolChoice?,
            stage: AIStage,
            configuration: AITurnConfiguration?,
            toolExecutor: (@Sendable ([AIToolCall]) async throws -> [AIMessage])?
        ) async throws -> AITurnResult {
            turns += 1
            guard turns == 1 else {
                return AITurnResult(assistantText: "Copied.", toolCalls: [])
            }
            let transcript = messages.compactMap { $0.content?.text }.joined(separator: "\n")
            guard let write = Self.slot(access: "write", in: transcript) else {
                throw ScriptError.noWriteSlot(transcript)
            }
            let arguments = try JSONSerialization.data(withJSONObject: [
                "command": command(Self.slot(access: "read", in: transcript), write)
            ])
            return AITurnResult(
                assistantText: nil,
                toolCalls: [
                    AIToolCall(
                        id: "shell-1",
                        name: SkillManager.shellToolName,
                        argumentsJSON: String(decoding: arguments, as: UTF8.self))
                ])
        }

        private static func slot(access: String, in transcript: String) -> String? {
            let pattern = #"\$(KT_(?:OTB|ATTACHMENT)_[A-Z0-9_]+)\s+file\s+"[^"]*"\s+"# + access
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(
                    in: transcript, range: NSRange(transcript.startIndex..., in: transcript)),
                let range = Range(match.range(at: 1), in: transcript)
            else { return nil }
            return String(transcript[range])
        }

        private enum ScriptError: Error { case noWriteSlot(String) }
    }
}
