#if canImport(Security)
import Foundation
import Security

/// Keychain-backed credential storage.
///
/// SimpleFIN Access URLs are bearer credentials, so they live here and never in
/// SwiftData, CloudKit, logs, or backups in plain text. A synchronizable item
/// must use `kSecAttrAccessibleAfterFirstUnlock`, because `...ThisDeviceOnly` is
/// not valid for iCloud Keychain. A device-only item uses
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so it cannot ride along in
/// an encrypted backup or move to a new device — otherwise "never leaves the
/// device" would not be true.
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

        let accessibility: CFString = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let valueAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
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
            // Moving back to iCloud must not leave the device-only copy behind,
            // or reads would keep preferring it forever.
            if synchronizable {
                try? delete(id: id, synchronizable: false)
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

        // Switching to iCloud may replace this device's own copy. Switching to
        // This Device Only must not delete the iCloud item: it belongs to the
        // whole iCloud Keychain, so removing it would silently stop sync on every
        // other signed-in device. Reads prefer the local copy instead.
        if synchronizable {
            try? delete(id: id, synchronizable: false)
        }
    }

    public func secret(for id: UUID) throws -> String? {
        // Prefer this device's own copy when both exist, so choosing This Device
        // Only keeps reading what the person chose.
        if let local = try secret(id: id, synchronizable: false) { return local }
        return try secret(id: id, synchronizable: true)
    }

    private func secret(id: UUID, synchronizable: Bool) throws -> String? {
        var query = commonAttributes(id: id)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecAttrSynchronizable as String] = synchronizable

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
        try attributes(id: id)?[kSecAttrSynchronizable as String] as? Bool
    }

    public func accessibility(for id: UUID) throws -> CredentialAccessibility? {
        guard let raw = try attributes(id: id)?[kSecAttrAccessible as String] as? String else { return nil }
        if raw == (kSecAttrAccessibleAfterFirstUnlock as String) { return .afterFirstUnlock }
        if raw == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) {
            return .afterFirstUnlockThisDeviceOnly
        }
        return .other
    }

    /// The item's attributes regardless of synchronizability, or `nil` when
    /// nothing is stored.
    private func attributes(id: UUID) throws -> [String: Any]? {
        var query = commonAttributes(id: id)
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? [String: Any]
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
        var accessibility: CredentialAccessibility
    }

    private let lock = NSLock()
    private var items: [UUID: Item] = [:]

    public init() {}

    public func store(_ secret: String, id: UUID, synchronizable: Bool) throws {
        try store(
            secret,
            id: id,
            synchronizable: synchronizable,
            accessibility: synchronizable ? .afterFirstUnlock : .afterFirstUnlockThisDeviceOnly
        )
    }

    /// Stores an item with an explicit accessibility class, mirroring what the
    /// Keychain would report. Tests use it to reproduce a credential written by
    /// an older build, which claimed to be device-only but carried the migratable
    /// class.
    public func store(
        _ secret: String,
        id: UUID,
        synchronizable: Bool,
        accessibility: CredentialAccessibility
    ) throws {
        lock.lock(); defer { lock.unlock() }
        items[id] = Item(secret: secret, synchronizable: synchronizable, accessibility: accessibility)
    }

    public func secret(for id: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[id]?.secret
    }

    public func isSynchronizable(for id: UUID) throws -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return items[id]?.synchronizable
    }

    public func accessibility(for id: UUID) throws -> CredentialAccessibility? {
        lock.lock(); defer { lock.unlock() }
        return items[id]?.accessibility
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
