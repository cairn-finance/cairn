#if canImport(Security)
import Foundation
import Security

/// Keychain-backed credential storage.
///
/// SimpleFIN Access URLs are bearer credentials, so they live here and never in
/// SwiftData, CloudKit, logs, or backups in plain text. Items are stored with
/// `kSecAttrAccessibleAfterFirstUnlock` because synchronizable items cannot use
/// `...ThisDeviceOnly`; the device passcode still protects them at rest.
///
/// On macOS, iCloud Keychain sync and per-app access groups require the **data
/// protection keychain** (Apple TN3137), so every operation targets it
/// explicitly with `kSecUseDataProtectionKeychain`.
public struct KeychainCredentialStore: CredentialStore {
    /// Keychain service name. Derived from the bundle identifier so different
    /// installs (and developers) never share keychain items.
    public static var defaultService: String {
        "\(Bundle.main.bundleIdentifier ?? "com.example.cairn").simplefin"
    }

    private static let label = "Cairn SimpleFIN Access URL"

    private let service: String

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    /// Attributes common to every operation, including targeting the data
    /// protection keychain on macOS.
    private func commonAttributes(id: UUID? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let id {
            query[kSecAttrAccount as String] = id.uuidString
        }
        query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        return query
    }

    public func store(_ secret: String, id: UUID, synchronizable: Bool) throws {
        guard let data = secret.data(using: .utf8) else {
            throw CredentialStoreError.malformedSecret
        }

        let valueAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel as String: Self.label,
        ]

        // If an item with the requested synchronizability already exists, update
        // it in place. `kSecAttrSynchronizable` is part of the item's identity,
        // so it cannot be changed by an update.
        if try itemExists(id: id, synchronizable: synchronizable) {
            var query = commonAttributes(id: id)
            query[kSecAttrSynchronizable as String] = synchronizable
            let status = SecItemUpdate(query as CFDictionary, valueAttributes as CFDictionary)
            guard status == errSecSuccess else {
                throw CredentialStoreError.unexpectedStatus(status)
            }
            return
        }

        // Add the new variant *first*. Only after it succeeds do we remove the
        // opposite variant, so a failed write can never lose the credential —
        // setup tokens are single-use and replacing one is disruptive.
        var addQuery = commonAttributes(id: id)
        addQuery[kSecAttrSynchronizable as String] = synchronizable
        addQuery.merge(valueAttributes) { _, new in new }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(status)
        }

        try? delete(id: id, synchronizable: !synchronizable)
    }

    public func secret(for id: UUID) throws -> String? {
        var query = commonAttributes(id: id)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError.malformedSecret
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    public func isSynchronizable(for id: UUID) throws -> Bool? {
        var query = commonAttributes(id: id)
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let attributes = result as? [String: Any]
            return attributes?[kSecAttrSynchronizable as String] as? Bool
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    public func delete(id: UUID) throws {
        // Delete regardless of the item's synchronizable flag.
        var query = commonAttributes(id: id)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    public func deleteAll() throws {
        var query = commonAttributes()
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    // MARK: - Helpers

    private func itemExists(id: UUID, synchronizable: Bool) throws -> Bool {
        var query = commonAttributes(id: id)
        query[kSecAttrSynchronizable as String] = synchronizable
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    private func delete(id: UUID, synchronizable: Bool) throws {
        var query = commonAttributes(id: id)
        query[kSecAttrSynchronizable as String] = synchronizable
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }
}

/// In-memory store used by previews and tests.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private struct Item {
        var secret: String
        var synchronizable: Bool
    }

    private let lock = NSLock()
    private var items: [UUID: Item] = [:]

    public init() {}

    public func store(_ secret: String, id: UUID, synchronizable: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        items[id] = Item(secret: secret, synchronizable: synchronizable)
    }

    public func secret(for id: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[id]?.secret
    }

    public func isSynchronizable(for id: UUID) throws -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return items[id]?.synchronizable
    }

    public func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        items[id] = nil
    }

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }
}
#endif
