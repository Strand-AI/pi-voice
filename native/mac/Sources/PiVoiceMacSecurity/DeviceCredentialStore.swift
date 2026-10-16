import Foundation
import PiVoiceMacCore
import Security

public struct DeviceCredential: Equatable, Sendable {
    public let origin: String
    public let value: String

    public init(origin: String, value: String) throws {
        try validateExactOrigin(origin)
        guard value.count == 43,
              value.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) ||
                  ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
              }) else {
            throw DeviceCredentialStoreError.invalidCredential
        }
        self.origin = origin
        self.value = value
    }
}

public protocol DeviceCredentialStore: Sendable {
    func load(origin: String) throws -> DeviceCredential?
    func save(_ credential: DeviceCredential) throws
    func delete(origin: String) throws
}

public struct DeviceCredentialVault: Sendable {
    private let store: any DeviceCredentialStore

    public init(store: any DeviceCredentialStore) { self.store = store }

    public func persist(value: String, echoedOrigin: String, expectedOrigin: String) throws {
        guard echoedOrigin == expectedOrigin else { throw DeviceCredentialVaultError.originMismatch }
        try store.save(DeviceCredential(origin: echoedOrigin, value: value))
    }

    public func load(origin: String) throws -> DeviceCredential? { try store.load(origin: origin) }
    public func contains(origin: String) throws -> Bool { try load(origin: origin) != nil }
    public func delete(origin: String) throws { try store.delete(origin: origin) }

    /// Deletes only the exact credential used by a failed temporary renewal.
    /// A late failure can never erase a newer re-pair for the same origin.
    public func deleteIfUnchanged(_ snapshot: DeviceCredential) throws {
        guard try store.load(origin: snapshot.origin) == snapshot else { return }
        try store.delete(origin: snapshot.origin)
    }
}

public enum DeviceCredentialVaultError: Error, Equatable, LocalizedError, Sendable {
    case originMismatch

    public var errorDescription: String? {
        "The gateway's echoed device origin did not match the exact requested origin."
    }
}

public enum DeviceCredentialStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidOrigin
    case invalidCredential
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidOrigin: "The saved device origin is invalid."
        case .invalidCredential: "The gateway returned an invalid device credential."
        case .keychain(let status): "macOS Keychain failed (status \(status))."
        }
    }
}

public struct KeychainDeviceCredentialStore: DeviceCredentialStore {
    public static let service = "ai.strand.pi-voice.device-credential"
    public static let synchronizesWithICloud = false

    public init() {}

    public func load(origin: String) throws -> DeviceCredential? {
        try validateExactOrigin(origin)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery(origin: origin).merging([
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw DeviceCredentialStoreError.keychain(status)
        }
        return try DeviceCredential(origin: origin, value: value)
    }

    public func save(_ credential: DeviceCredential) throws {
        let data = Data(credential.value.utf8)
        let query = baseQuery(origin: credential.origin)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw DeviceCredentialStoreError.keychain(updateStatus) }

        let add = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "Pi Voice paired device",
        ]) { _, new in new }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw DeviceCredentialStoreError.keychain(addStatus) }
    }

    public func delete(origin: String) throws {
        try validateExactOrigin(origin)
        let status = SecItemDelete(baseQuery(origin: origin) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceCredentialStoreError.keychain(status)
        }
    }

    /// Exposed for deterministic policy checks without creating a real Keychain item.
    public func policyAttributes(origin: String) throws -> [String: Any] {
        try validateExactOrigin(origin)
        return baseQuery(origin: origin).merging([
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]) { _, new in new }
    }

    private func baseQuery(origin: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: origin,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

private func validateExactOrigin(_ origin: String) throws {
    guard let url = URL(string: origin),
          let gateway = try? GatewayConfiguration(baseURL: url),
          gateway.origin == origin else {
        throw DeviceCredentialStoreError.invalidOrigin
    }
}
