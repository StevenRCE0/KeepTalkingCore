import Foundation
import MCP

public enum PrimitiveActionManagerError: LocalizedError {
    case invalidAction
    case missingActionID
    case missingCallback

    public var errorDescription: String? {
        switch self {
            case .invalidAction:
                return "Action payload is not a primitive bundle."
            case .missingActionID:
                return "Action must have an ID before registration."
            case .missingCallback:
                return
                    "Primitive action callback is not configured for this client."
        }
    }
}

public actor PrimitiveActionManager {
    private let callback: KeepTalkingPrimitiveActionCallback?
    private var primitiveBundlesByActionID: [UUID: KeepTalkingPrimitiveBundle] =
        [:]

    public init(
        callback: KeepTalkingPrimitiveActionCallback?
    ) {
        self.callback = callback
    }

    public func registerPrimitiveAction(_ action: KeepTalkingAction) async throws {
        guard case .primitive(let primitiveBundle) = action.payload else {
            throw PrimitiveActionManagerError.invalidAction
        }
        guard let actionID = action.id else {
            throw PrimitiveActionManagerError.missingActionID
        }
        primitiveBundlesByActionID[actionID] = primitiveBundle
    }

    public func refreshPrimitiveAction(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw PrimitiveActionManagerError.missingActionID
        }
        primitiveBundlesByActionID.removeValue(forKey: actionID)
        try await registerPrimitiveAction(action)
    }

    public func unregisterAction(actionID: UUID) async {
        primitiveBundlesByActionID.removeValue(forKey: actionID)
    }

    public func registerIfNeeded(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw PrimitiveActionManagerError.missingActionID
        }
        if primitiveBundlesByActionID[actionID] == nil {
            try await registerPrimitiveAction(action)
        }
    }

    public func callAction(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        guard case .primitive(let primitiveBundle) = action.payload else {
            throw PrimitiveActionManagerError.invalidAction
        }
        guard let callback else {
            throw PrimitiveActionManagerError.missingCallback
        }
        try await registerIfNeeded(action)

        let response = try await callback(primitiveBundle, call)
        return (
            content: [.text(text: response.text, annotations: nil, _meta: nil)],
            isError: response.isError
        )
    }
}
