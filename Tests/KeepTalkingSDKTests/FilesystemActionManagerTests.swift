import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

struct FilesystemActionManagerTests {
    @Test("sed replaces multiline text with structured arguments")
    func multilineSed() async throws {
        let fixture = try Fixture(content: "before\nstart\nmiddle\nend\nafter\n")
        defer { fixture.remove() }

        _ = try await fixture.callSed([
            "pattern": .string("start.*end"),
            "replacement": .string("new\nblock"),
            "flags": .string("s"),
        ])

        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "before\nnew\nblock\nafter\n")
    }

}

private struct Fixture {
    let root: URL
    let file: URL
    let action: KeepTalkingAction

    init(content: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("filesystem-action-\(UUID())", isDirectory: true)
        file = root.appendingPathComponent("fixture.txt")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
        action = KeepTalkingAction(
            payload: .filesystem(KeepTalkingFilesystemBundle(rootPath: root.path)),
            remoteAuthorisable: false,
            blockingAuthorisation: false
        )
    }

    func callSed(_ arguments: [String: Value]) async throws -> [Tool.Content] {
        var arguments = arguments
        arguments["operation"] = .string(KeepTalkingFilesystemOperation.sed.rawValue)
        arguments["path"] = .string(file.lastPathComponent)
        return try await FilesystemActionManager().callAction(
            action: action,
            call: KeepTalkingActionCall(
                action: try #require(action.id),
                arguments: arguments
            ),
            scope: .all,
            contextID: UUID(),
            callerNodeID: UUID(),
            isLocalExecution: true
        ).content
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
