import Foundation
import Testing

@testable import KeepTalkingSDK

/// Filesystem behaviour as the agent experiences it.
///
/// These reproduce a real incident: asked to feed a PDF into a converter, the
/// agent called `get-file`, got back a sentence containing a path but no handle
/// it could pass anywhere, retried six times, and finally reached for
/// `write-file` to "produce" the output — overwriting the 867KB source PDF with
/// 36 bytes. Both halves of that are covered here: `get-file` must hand back
/// something usable, and `write-file` must not silently destroy a file.
struct FilesystemAgentSurfaceTests {

    // MARK: - get-file hands the agent a usable handle

    @Test("get-file on the local node produces a handle, not just a path")
    func localGetFileProducesHandle() async throws {
        try await AgentSurface.withFilesystem { _, fs in
            try fs.seed("report.pdf", bytes: Data("%PDF-1.7\nbinary enough\n".utf8))

            let reply = try await fs.call("get-file", ["path": "report.pdf"])

            #expect(reply.ok)
            let handle = try reply.onlyHandle()
            #expect(handle.kind == "otb")
            #expect(handle.name == "report.pdf")
            #expect(handle.origin == "produced")
            // The regression: before the fix this array was empty and the agent
            // was left holding a sentence about a path.
            #expect(handle.handle.hasPrefix("KT_"))
        }
    }

    @Test("the handle get-file returns resolves to the file's bytes")
    func localGetFileHandleResolvesToBytes() async throws {
        try await AgentSurface.withFilesystem { surface, fs in
            let pdf = Data((0..<4096).map { UInt8($0 % 251) })
            try fs.seed("report.pdf", bytes: pdf)

            let reply = try await fs.call("get-file", ["path": "report.pdf"])
            let handle = try reply.onlyHandle()

            // Resolving is what a downstream action does with an input handle.
            // A handle that does not resolve is the same failure as no handle.
            let resolved = try #require(
                await surface.resolve(handle),
                "the handle the agent was given did not resolve to any file")
            #expect(try Data(contentsOf: resolved) == pdf)
        }
    }

    @Test("get-file never modifies the file it reads")
    func localGetFileLeavesSourceIntact() async throws {
        try await AgentSurface.withFilesystem { _, fs in
            let pdf = Data((0..<8192).map { UInt8($0 % 97) })
            try fs.seed("report.pdf", bytes: pdf)

            _ = try await fs.call("get-file", ["path": "report.pdf"])

            #expect(fs.bytes("report.pdf") == pdf)
            #expect(fs.size("report.pdf") == pdf.count)
        }
    }

    @Test("get-file reports the file's size so the agent can sanity-check it")
    func localGetFileReportsSize() async throws {
        try await AgentSurface.withFilesystem { _, fs in
            try fs.seed("report.pdf", bytes: Data(repeating: 0x41, count: 867_576))

            let reply = try await fs.call("get-file", ["path": "report.pdf"])

            #expect(reply.text.contains("867576"))
        }
    }

    // MARK: - write-file refuses to destroy data

    @Test("write-file refuses to overwrite an existing file")
    func writeFileRefusesClobber() async throws {
        try await AgentSurface.withFilesystem { _, fs in
            let original = Data(repeating: 0x7F, count: 867_576)
            try fs.seed("not-yet-trading.pdf", bytes: original)

            // Verbatim shape of the call that destroyed the real file.
            let reply = try await fs.call(
                "write-file",
                [
                    "path": "not-yet-trading.pdf",
                    "content": "Output written via get-file transfer",
                ])

            #expect(!reply.ok)
            #expect(fs.bytes("not-yet-trading.pdf") == original)
            #expect(fs.size("not-yet-trading.pdf") == 867_576)
        }
    }

    @Test("the refusal tells the agent which tool it should have reached for")
    func refusalNamesTheRightTool() async throws {
        try await AgentSurface.withFilesystem { _, fs in
            try fs.seed(
                "not-yet-trading.pdf", bytes: Data(repeating: 0x7F, count: 4096))

            let reply = try await fs.call(
                "write-file",
                ["path": "not-yet-trading.pdf", "content": "placeholder"])

            // An agent that gets a bare "denied" retries. One that is told what
            // to call instead can recover on its own.
            let message = reply.errorMessage + reply.text
            #expect(message.contains("get-file"))
            #expect(message.contains("overwrite=true"))
        }
    }

    @Test("write-file still creates a file at a fresh path")
    func writeFileCreatesNewFile() async throws {
        try await AgentSurface.withFilesystem { _, fs in
            let reply = try await fs.call(
                "write-file", ["path": "notes/summary.md", "content": "# Summary\n"])

            #expect(reply.ok)
            #expect(fs.bytes("notes/summary.md") == Data("# Summary\n".utf8))
        }
    }

    @Test("write-file replaces the file when the agent asks for it explicitly")
    func writeFileOverwritesWhenAsked() async throws {
        try await AgentSurface.withFilesystem { _, fs in
            try fs.seed("draft.md", text: "old draft")

            let reply = try await fs.call(
                "write-file",
                ["path": "draft.md", "content": "new draft", "overwrite": true])

            #expect(reply.ok)
            #expect(fs.bytes("draft.md") == Data("new draft".utf8))
        }
    }

    @Test("an empty file is not data, so writing over it is allowed")
    func writeFileOverwritesEmptyPlaceholder() async throws {
        try await AgentSurface.withFilesystem { _, fs in
            try fs.seed("placeholder.txt", bytes: Data())

            let reply = try await fs.call(
                "write-file", ["path": "placeholder.txt", "content": "real content"])

            #expect(reply.ok)
            #expect(fs.bytes("placeholder.txt") == Data("real content".utf8))
        }
    }

    // MARK: - The whole incident, end to end

    @Test("fetching a binary and feeding it onward no longer needs a write")
    func fetchThenHandOffWithoutTouchingSource() async throws {
        try await AgentSurface.withFilesystem { surface, fs in
            let original = Data((0..<200_000).map { UInt8($0 % 253) })
            try fs.seed("not-yet-trading.pdf", bytes: original)

            // 1. The agent fetches the binary it was asked to summarise.
            let fetched = try await fs.call(
                "get-file", ["path": "not-yet-trading.pdf"])
            let handle = try fetched.onlyHandle()

            // 2. It now holds something it can pass as another action's input.
            let staged = try #require(await surface.resolve(handle))
            #expect(try Data(contentsOf: staged) == original)

            // 3. And the file it was reading is exactly as it found it.
            #expect(fs.bytes("not-yet-trading.pdf") == original)
        }
    }
}

/// Recovering from a mistyped action reference.
///
/// On 2026-08-19 the agent turned `…946e…` into `…946b…` while retyping an
/// action's UUID, got a bare `unknown_action_id`, and concluded from that one
/// word that the action host had gone down — then told the user to paste their
/// documents by hand. The action was alive and the id was one nibble off.
///
/// Actions are now referenced by `friendlyName`, which is what makes that class
/// of slip recoverable: hex has no redundancy, words do.
struct MistypedActionReferenceTests {

    /// The real action from the incident.
    private var incidentAction: UUID {
        UUID(uuidString: "019EBBD5-8D87-7000-946E-76135023BD00")!
    }

    @Test("the incident's action has a stable three-word name")
    func incidentActionHasFriendlyName() {
        let name = incidentAction.friendlyNameToken
        #expect(name.split(separator: "-").count == 3)
        #expect(name == incidentAction.friendlyNameToken)
    }

    @Test("dropping a letter from the name still reaches the right action")
    func droppedLetterStillResolves() throws {
        let other = UUID()
        var words = incidentAction.friendlyNameToken.split(separator: "-").map(String.init)
        words[1] = String(words[1].dropLast())
        let mistyped = words.joined(separator: "-")

        guard
            case .corrected(let id, _, let to) =
                UUIDFriendlyName.resolve(mistyped, among: [incidentAction, other])
        else {
            Issue.record("expected repair of '\(mistyped)'")
            return
        }
        #expect(id == incidentAction)
        #expect(to == incidentAction.friendlyNameToken)
    }

    @Test("the exact hex slip from the incident is still refused, not guessed")
    func theOriginalHexSlipIsNotGuessed() {
        // Deliberate: repairing hex would mean silently running some other
        // action. The agent gets the action roster back instead.
        let mistyped = "019ebbd5-8d87-7000-946b-76135023bd00"
        #expect(UUIDFriendlyName.resolve(mistyped, among: [incidentAction]) == .unknown)
    }

    @Test("the correct hex id keeps working, so nothing that worked breaks")
    func correctHexStillResolves() {
        #expect(
            UUIDFriendlyName.resolve(incidentAction.uuidString, among: [incidentAction])
                == .resolved(incidentAction))
    }

    @Test("two real actions do not share a name")
    func realActionsDoNotCollide() {
        // Both ids from the incident's own action listing.
        let business = incidentAction
        let selfEvolution = UUID(uuidString: "019FA7D1-0805-7000-9553-43AB12EE4CAA")!
        #expect(business.friendlyNameToken != selfEvolution.friendlyNameToken)
        #expect(business.friendlyName != selfEvolution.friendlyName)
    }
}
