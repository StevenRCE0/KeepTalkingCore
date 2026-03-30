import Foundation
import Testing

@testable import KeepTalkingSDK

struct PrimitiveActionSchemaTests {
    @Test("ask-for-file schema exposes picker selection modes")
    func askForFileSchemaIncludesPickerModes() throws {
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: UUID(),
                node: UUID()
            ),
            localStore: KeepTalkingInMemoryStore()
        )
        let definition = client.makePrimitiveActionProxyDefinition(
            actionID: UUID(),
            ownerNodeID: UUID(),
            bundle: KeepTalkingPrimitiveBundle(
                name: "ask-for-file",
                indexDescription: "Ask for a file",
                action: .askForFile
            ),
            descriptor: nil
        )

        let data = try JSONEncoder().encode(definition.parameters)
        let jsonObject = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let properties = try #require(
            jsonObject["properties"] as? [String: Any]
        )
        let picker = try #require(properties["picker"] as? [String: Any])
        let values = try #require(picker["enum"] as? [String])

        #expect(values == ["ask", "filePicker", "photoPicker"])
    }
}
