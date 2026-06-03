#if canImport(Security)
import Foundation
import Security

/// `SecItem*`-backed `KeepTalkingKeychainStore` for iOS/macOS apps.
///
/// Items rely on the consuming target's `keychain-access-groups` entitlement —
/// when entitled to a single shared group across the main app and its
/// extensions, items are written to and read from that group automatically.
public final class KeepTalkingSecItemKeychainStore: KeepTalkingKeychainStore, @unchecked Sendable {
    public static let shared = KeepTalkingSecItemKeychainStore()

    private static let serviceRoot = "org.rcex.KeepTalkingApp"

    public init() {}

    public func get(_ key: KeepTalkingKeychainKey) async throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
            case errSecSuccess:
                return result as? Data
            case errSecItemNotFound:
                return nil
            default:
                throw KeepTalkingKeychainStoreError.osStatus(status)
        }
    }

    public func set(_ key: KeepTalkingKeychainKey, value: Data) async throws {
        let updateQuery = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: value
        ]

        let updateStatus = SecItemUpdate(
            updateQuery as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeepTalkingKeychainStoreError.osStatus(updateStatus)
        }

        var addQuery = updateQuery
        addQuery[kSecValueData as String] = value
        addQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeepTalkingKeychainStoreError.osStatus(addStatus)
        }
    }

    public func delete(_ key: KeepTalkingKeychainKey) async throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeepTalkingKeychainStoreError.osStatus(status)
        }
    }

    public func deleteAll() async throws {
        for kind in allKinds {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service(for: kind),
                kSecAttrSynchronizable as String: kCFBooleanFalse!,
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw KeepTalkingKeychainStoreError.osStatus(status)
            }
        }
    }

    private var allKinds: [KeepTalkingKeychainKey.Kind] {
        [.groupSecret, .nodeIdentityPriv, .loginCredential]
    }

    private func service(for kind: KeepTalkingKeychainKey.Kind) -> String {
        "\(Self.serviceRoot).\(kind.rawValue)"
    }

    private func baseQuery(for key: KeepTalkingKeychainKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: key.kind),
            kSecAttrAccount as String: key.id,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }
}

public enum KeepTalkingKeychainStoreError: Error, LocalizedError {
    case osStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
            case .osStatus(let status):
                return "Keychain operation failed (OSStatus \(status))"
        }
    }
}
#endif
