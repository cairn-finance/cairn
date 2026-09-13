import Foundation
#if canImport(Security)
import Security
#endif

/// Abstraction over secret storage so the sync engine and onboarding flow can
/// be tested without touching the real Keychain.
public protocol CredentialStore: Sendable {
    /// Stores (or replaces) a secret for `id`.
    /// - Parameter synchronizable: when `true` the item syncs through the
    ///   user's iCloud Keychain (end-to-end encrypted). Local-only mode passes
    ///   `false` so the credential never leaves the device.
    func store(_ secret: String, id: UUID, synchronizable: Bool) throws

    /// Reads a secret, or `nil` when none is stored.
    func secret(for id: UUID) throws -> String?

    /// Whether the stored item currently syncs through iCloud Keychain, or `nil`
    /// when no item is stored. Used to avoid rewriting (and churning the synced
    /// copy of) a credential that already has the desired mode.
    func isSynchronizable(for id: UUID) throws -> Bool?

    func delete(id: UUID) throws

    func deleteAll() throws
}

public enum CredentialStoreError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case malformedSecret

    public var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            "Keychain error \(status)\(Self.hint(for: status))."
        case .malformedSecret:
            "The stored credential could not be read."
        }
    }

    /// A short, non-sensitive explanation for the common failures, so the UI can
    /// tell a person what to do instead of showing a raw status code.
    static func hint(for status: OSStatus) -> String {
        #if canImport(Security)
        switch status {
        case errSecNotAvailable:
            " (iCloud Keychain is unavailable or turned off)"
        case errSecMissingEntitlement:
            " (the app is missing its keychain entitlement — check code signing)"
        case errSecInteractionNotAllowed:
            " (the keychain is locked until the device is unlocked once)"
        case errSecAuthFailed:
            " (the keychain refused access)"
        case errSecDuplicateItem:
            " (an item already exists)"
        default:
            ""
        }
        #else
        ""
        #endif
    }
}
