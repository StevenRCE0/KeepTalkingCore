import AIProxy
import Foundation
import Testing

@testable import KeepTalkingSDK

struct PrimitiveActionSchemaTests {
    @Test("ask-for-file schema exposes picker selection modes")
    func askForFileSchemaIncludesPickerModes() async throws {
        let askForFileParameters: [String: AIProxyJSONValue] = [
            "type": .string("object"),
            "properties": .object([
                "picker": .object([
                    "type": .string("string"),
                    "enum": .array([.string("ask"), .string("filePicker"), .string("photoPicker")]),
                    "description": .string("Which picker UI to present."),
                ]),
                "allowedTypes": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ]),
                "allowMultiple": .object(["type": .string("boolean")]),
            ]),
            "additionalProperties": .bool(false),
        ]

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: UUID(),
                node: UUID()
            ),
            primitiveRegistry: KeepTalkingPrimitiveRegistry(
                toolParameters: { _ in askForFileParameters },
                callAction: { _, _ in KeepTalkingPrimitiveActionResponse(text: "") }
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
