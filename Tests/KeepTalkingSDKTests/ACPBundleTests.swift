import Foundation
import Testing

@testable import KeepTalkingSDK

struct ACPBundleTests {
    @Test("ACP bundle round-trips through the Payload Codable")
    func bundlePayloadRoundTrip() throws {
        let bundle = KeepTalkingACPBundle(
            name: "claude",
            indexDescription: "Claude Code agent",
            command: ["claude", "--acp"],
            environment: ["ANTHROPIC_API_KEY": "x"],
            cwd: URL(fileURLWithPath: "/tmp/proj"),
            additionalDirectories: [URL(fileURLWithPath: "/tmp/shared")]
        )
        let payload = KeepTalkingAction.Payload.acp(bundle)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(KeepTalkingAction.Payload.self, from: data)

        guard case .acp(let out) = decoded else {
            Issue.record("Expected a `.acp` payload after round-trip")
            return
        }
        #expect(out.name == "claude")
        #expect(out.command == ["claude", "--acp"])
        #expect(out.cwd.path == "/tmp/proj")
        #expect(out.additionalDirectories.map(\.path) == ["/tmp/shared"])
        #expect(out.environment["ANTHROPIC_API_KEY"] == "x")
        #expect(payload.typeName == "ACP")
    }

    @Test("ACP payload has no per-grant editor and consumes no file input")
    func acpPayloadFlags() {
        let payload = KeepTalkingAction.Payload.acp(
            KeepTalkingACPBundle(name: "a", cwd: URL(fileURLWithPath: "/tmp"))
        )
        #expect(!payload.hasGrantPermissionEditor)
        let action = KeepTalkingAction(
            payload: payload, remoteAuthorisable: false, blockingAuthorisation: false)
        #expect(!action.acceptsFileInput)
        #expect(action.actionLabel == "a")
    }
}
