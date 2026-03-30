import Foundation

public enum KeepTalkingPushWakePurpose: String, Codable, Sendable, Hashable {
    case contextMessage = "context_message"
    case actionAuthorisation = "action_authorisation"
}

public struct KeepTalkingPushWakeHandle: Codable, Sendable, Hashable {
    public var id: UUID
    public var purpose: KeepTalkingPushWakePurpose
    public var contextID: UUID?
    public var relationID: UUID?
    public var actionID: UUID?
    public var opaqueValue: String
    public var topic: String
    public var environment: String

    public init(
        id: UUID = UUID(),
        purpose: KeepTalkingPushWakePurpose,
        contextID: UUID? = nil,
        relationID: UUID? = nil,
        actionID: UUID? = nil,
        opaqueValue: String,
        topic: String,
        environment: String
    ) {
        self.id = id
        self.purpose = purpose
        self.contextID = contextID
        self.relationID = relationID
        self.actionID = actionID
        self.opaqueValue = opaqueValue
        self.topic = topic
        self.environment = environment
    }
}

public struct KeepTalkingActionWakeRoute: Codable, Sendable, Hashable {
    public var actionID: UUID
    public var wakeHandles: [KeepTalkingPushWakeHandle]

    public init(actionID: UUID, wakeHandles: [KeepTalkingPushWakeHandle]) {
        self.actionID = actionID
        self.wakeHandles = wakeHandles
    }
}

public struct KeepTalkingPushWakeMessagePreview: Codable, Sendable, Hashable {
    public var sender: KeepTalkingContextMessage.Sender
    public var content: String
    public var isTruncated: Bool

    public init(
        sender: KeepTalkingContextMessage.Sender,
        content: String,
        isTruncated: Bool
    ) {
        self.sender = sender
        self.content = content
        self.isTruncated = isTruncated
    }
}

public struct KeepTalkingPushWakeContextEnvelope: Codable, Sendable, Hashable {
    public var contextID: UUID
    public var ciphertext: String

    public init(
        contextID: UUID,
        ciphertext: String
    ) {
        self.contextID = contextID
        self.ciphertext = ciphertext
    }

    public static func decode(
        from userInfo: [AnyHashable: Any]
    ) -> KeepTalkingPushWakeContextEnvelope? {
        if let json = userInfo["kt_context_wake"] as? String,
            let data = json.data(using: .utf8)
        {
            return try? JSONDecoder().decode(Self.self, from: data)
        }

        if let object = userInfo["kt_context_wake"],
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object)
        {
            return try? JSONDecoder().decode(Self.self, from: data)
        }

        return nil
    }
}

public struct KeepTalkingPushWakeActionPayload: Codable, Sendable, Hashable {
    public var contextID: UUID
    public var senderNodeID: UUID
    public var actionID: UUID

    public init(
        contextID: UUID,
        senderNodeID: UUID,
        actionID: UUID
    ) {
        self.contextID = contextID
        self.senderNodeID = senderNodeID
        self.actionID = actionID
    }
}

extension KeepTalkingAsymmetricCipherEnvelope {
    public static func decodePushWakeActionEnvelope(
        from userInfo: [AnyHashable: Any]
    ) -> KeepTalkingAsymmetricCipherEnvelope? {
        if let json = userInfo["kt_action_wake"] as? String,
            let data = json.data(using: .utf8)
        {
            return try? JSONDecoder().decode(Self.self, from: data)
        }

        if let object = userInfo["kt_action_wake"],
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object)
        {
            return try? JSONDecoder().decode(Self.self, from: data)
        }

        return nil
    }
}

public struct KeepTalkingPushWakeMintScope: Codable, Sendable, Hashable {
    public var purpose: KeepTalkingPushWakePurpose
    public var contextID: UUID?
    public var relationID: UUID?
    public var actionID: UUID?

    public init(
        purpose: KeepTalkingPushWakePurpose,
        contextID: UUID? = nil,
        relationID: UUID? = nil,
        actionID: UUID? = nil
    ) {
        self.purpose = purpose
        self.contextID = contextID
        self.relationID = relationID
        self.actionID = actionID
    }
}

public struct KeepTalkingPushWakeMintRequest: Codable, Sendable {
    public var token: String
    public var topic: String
    public var environment: String
    public var scopes: [KeepTalkingPushWakeMintScope]

    public init(
        token: String,
        topic: String,
        environment: String,
        scopes: [KeepTalkingPushWakeMintScope]
    ) {
        self.token = token
        self.topic = topic
        self.environment = environment
        self.scopes = scopes
    }
}

public struct KeepTalkingPushWakeMintResponse: Codable, Sendable {
    public var handles: [KeepTalkingPushWakeHandle]

    public init(handles: [KeepTalkingPushWakeHandle]) {
        self.handles = handles
    }
}

public struct KeepTalkingPushWakeSendRequest: Codable, Sendable {
    public var handle: KeepTalkingPushWakeHandle
    public var contextEnvelope: KeepTalkingPushWakeContextEnvelope?
    public var actionEnvelope: KeepTalkingAsymmetricCipherEnvelope?

    public init(
        handle: KeepTalkingPushWakeHandle,
        contextEnvelope: KeepTalkingPushWakeContextEnvelope? = nil,
        actionEnvelope: KeepTalkingAsymmetricCipherEnvelope? = nil
    ) {
        self.handle = handle
        self.contextEnvelope = contextEnvelope
        self.actionEnvelope = actionEnvelope
    }
}

public struct KeepTalkingPushWakeSendResponse: Codable, Sendable {
    public var accepted: Bool
    public var messageID: String?

    public init(accepted: Bool, messageID: String? = nil) {
        self.accepted = accepted
        self.messageID = messageID
    }
}
