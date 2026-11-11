import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

struct PluginWireTests {
    @Test("app messages encode flat: the node, the id, and exactly one body key")
    func flatAppMessage() throws {
        let message = KTPPWire.AppMessage(id: 3, from: "n1", reveal: .init())
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "from", "reveal"])
    }

    @Test("companion messages decode by body key, and a body from a newer peer is simply absent")
    func companionMessage() throws {
        let act = try JSONDecoder().decode(
            KTPPWire.CompanionMessage.self,
            from: Data(#"{"id": 4, "to": "n2", "act": {"requestID": "r9", "task": "t"}}"#.utf8))
        #expect(act.to == "n2")
        #expect(act.act?.requestID == "r9")

        let newer = try JSONDecoder().decode(
            KTPPWire.CompanionMessage.self, from: Data(#"{"id": 5, "somethingNew": {"x": 1}}"#.utf8))
        #expect(newer.id == 5 && newer.act == nil && newer.failure == nil)

        let failure = try JSONDecoder().decode(
            KTPPWire.CompanionMessage.self,
            from: Data(#"{"replyTo": 6, "failure": {"code": "not_connected", "message": "m"}}"#.utf8))
        #expect(failure.failure?.code == "not_connected")
    }
}
