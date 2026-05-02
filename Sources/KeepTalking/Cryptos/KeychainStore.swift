import Foundation

public struct KeepTalkingKeychainKey: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case groupSecret = "group-secret"
        case nodeIdentityPriv = "node-identity-priv"
        case loginCredential = "login-credential"
    }

    public let kind: Kind
    public let id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    public static func groupSecret(contextID: UUID) -> KeepTalkingKeychainKey {
        KeepTalkingKeychainKey(kind: .groupSecret, id: contextID.uuidString.lowercased())
    }

    public static func nodeIdentityPriv(relationID: UUID) -> KeepTalkingKeychainKey {
        KeepTalkingKeychainKey(kind: .nodeIdentityPriv, id: relationID.uuidString.lowercased())
    }

    public static func loginCredential(id: String) -> KeepTalkingKeychainKey {
        KeepTalkingKeychainKey(kind: .loginCredential, id: id)
    }
}

public protocol KeepTalkingKeychainStore: Sendable {
    func get(_ key: KeepTalkingKeychainKey) async throws -> Data?
    func set(_ key: KeepTalkingKeychainKey, value: Data) async throws
    func delete(_ key: KeepTalkingKeychainKey) async throws
    func deleteAll() async throws
}

public actor KeepTalkingInMemoryKeychainStore: KeepTalkingKeychainStore {
    private var storage: [KeepTalkingKeychainKey: Data] = [:]

    public init() {}

    public func get(_ key: KeepTalkingKeychainKey) async throws -> Data? {
        storage[key]
    }

    public func set(_ key: KeepTalkingKeychainKey, value: Data) async throws {
        storage[key] = value
    }

    public func delete(_ key: KeepTalkingKeychainKey) async throws {
        storage.removeValue(forKey: key)
    }

    public func deleteAll() async throws {
        storage.removeAll()
    }
}
