import Foundation
import PiVoiceCore
import Security

/// Stores only the opaque durable device credential. The exact canonical origin is the
/// Keychain account key; no session cookie, pairing token, root bearer, or metadata is stored.
final class KeychainDeviceCredentialStore: DurableDeviceCredentialStore {
    private let service = "ai.strand.pivoice.device-credential"

    func load(origin: String) throws -> DurableDeviceCredential? {
        var query = baseQuery(origin: origin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status)
        }
        do { return try DurableDeviceCredential(origin: origin, value: value) }
        catch {
            try? delete(origin: origin)
            throw error
        }
    }

    func save(_ credential: DurableDeviceCredential) throws {
        let data = Data(credential.value.utf8)
        let updateStatus = SecItemUpdate(baseQuery(origin: credential.origin) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(updateStatus) }
        var item = baseQuery(origin: credential.origin)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(addStatus) }
    }

    func delete(origin: String) throws {
        let status = SecItemDelete(baseQuery(origin: origin) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }

    private func baseQuery(origin: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: origin,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var errorDescription: String? { "Secure device credential storage failed (\(status))." }
}
