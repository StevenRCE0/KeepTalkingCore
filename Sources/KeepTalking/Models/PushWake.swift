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
        id: UUID = UUID.v7(),
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
    /// The `userInfo` key a delivered notification keeps its message id
    /// under, so a revocation can find it.
    public static let messageIDUserInfoKey = "kt_message_id"

    public var sender: KeepTalkingContextMessage.Sender
    public var content: String
    public var isTruncated: Bool
    /// Absent in previews from nodes that predate revocation.
    public var messageID: UUID?

    public init(
        sender: KeepTalkingContextMessage.Sender,
        content: String,
        isTruncated: Bool,
        messageID: UUID? = nil
    ) {
        self.sender = sender
        self.content = content
        self.isTruncated = isTruncated
        self.messageID = messageID
    }
}

/// Takes back the notifications a context wake raised for deleted messages.
/// Sealed with the group secret, like a preview, so the relay never sees
/// which messages went.
public struct KeepTalkingPushWakeRevocation: Codable, Sendable, Hashable {
    public var messageIDs: [UUID]

    public init(messageIDs: [UUID]) {
        self.messageIDs = messageIDs
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
        decode(userInfo["kt_context_wake"])
    }

    /// The envelope of a silent revocation push, whose ciphertext seals a
    /// ``KeepTalkingPushWakeRevocation`` rather than a preview.
    public static func decodeRevocation(
        from userInfo: [AnyHashable: Any]
    ) -> KeepTalkingPushWakeContextEnvelope? {
        decode(userInfo["kt_context_revoke"])
    }

    private static func decode(_ value: Any?) -> KeepTalkingPushWakeContextEnvelope? {
        if let json = value as? String,
            let data = json.data(using: .utf8)
        {
            return try? JSONDecoder().decode(Self.self, from: data)
        }

        if let object = value,
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
    /// What the push carries. `.context` and `.revocation` ride a
    /// `.contextMessage` handle, `.action` an `.actionAuthorisation` one.
    public enum Wake: Codable, Sendable {
        case context(envelope: KeepTalkingPushWakeContextEnvelope)
        case action(envelope: KeepTalkingAsymmetricCipherEnvelope)
        /// Sent as a silent background push.
        case revocation(envelope: KeepTalkingPushWakeContextEnvelope)
    }

    public var handle: KeepTalkingPushWakeHandle
    public var wake: Wake

    public init(handle: KeepTalkingPushWakeHandle, wake: Wake) {
        self.handle = handle
        self.wake = wake
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
