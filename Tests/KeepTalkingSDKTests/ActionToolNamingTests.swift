import Foundation
import Testing

@testable import KeepTalkingSDK

struct ActionToolNamingTests {
    @Test("function_name is tagged and stable across catalog rebuilds")
    func functionNameTaggedAndStable() {
        let ownerNodeID = UUID(uuidString: "158010DE-FAF8-4B04-842D-0D0CD022AAB6")!
        let actionID = UUID(uuidString: "9D86068C-CE26-42EA-B037-81AAC1869002")!
        let shortAction = KeepTalkingActionToolDefinition.shortActionID(actionID)

        let first = KeepTalkingActionToolDefinition.normalizedFunctionName(
            ownerNodeID: ownerNodeID,
            actionID: actionID,
            targetName: "get-weather"
        )
        let second = KeepTalkingActionToolDefinition.normalizedFunctionName(
            ownerNodeID: ownerNodeID,
            actionID: actionID,
            targetName: "get-weather"
        )

        #expect(first == second)
        #expect(first.contains("_\(shortAction)"))
        #expect(first.count <= 64)
    }

    @Test("catalog tagged tool_name can be unrouted for call dispatch")
    func routedNameRoundTrip() {
        let actionID = UUID(uuidString: "9D86068C-CE26-42EA-B037-81AAC1869002")!
        let shortAction = KeepTalkingActionToolDefinition.shortActionID(actionID)
        let rawToolName = "get-weather"

        let tagged = KeepTalkingActionToolDefinition.routedActionName(
            rawToolName,
            actionID: actionID
        )

        #expect(tagged == "\(rawToolName)__\(shortAction)")
        #expect(
            KeepTalkingActionToolDefinition.routedActionName(
                tagged,
                actionID: actionID
            ) == tagged
        )
        #expect(
            KeepTalkingActionToolDefinition.unroutedActionName(
                tagged,
                actionID: actionID
            ) == rawToolName
        )

        let otherAction = UUID(uuidString: "c115cd0f-6739-4ecc-8f35-c45adbdcbd42")!
        #expect(
            KeepTalkingActionToolDefinition.unroutedActionName(
                tagged,
                actionID: otherAction
            ) == tagged
        )
    }
}
