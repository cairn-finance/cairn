import Foundation
#if canImport(Security)
import Security
#endif

/// The Keychain accessibility class Cairn cares about.
///
/// A synced item must be readable after the first unlock; a device-only item must
/// never be able to ride along in an encrypted backup or restore onto a new
/// device. An item written by an older build can be device-only and still carry
/// the migratable class, which is the one case worth rewriting.
public enum CredentialAccessibility: Sendable, Equatable {
    /// Readable after the first unlock. The only class iCloud Keychain accepts.
    case afterFirstUnlock
    /// Readable after the first unlock and never leaves this device.
    case afterFirstUnlockThisDeviceOnly
    /// A class Cairn doesn't write, treated as needing a rewrite.
    case other
}

/// Whether a stored credential needs rewriting to match the wanted sync mode.
public enum CredentialMigration {
    /// Rewriting a synced item pushes a new revision through iCloud Keychain to
    /// every device, so it has to happen only when something actually differs —
    /// otherwise every launch of every device generates sync traffic.
    public static func needsRewrite(
        currentSynchronizable: Bool?,
        currentAccessibility: CredentialAccessibility?,
        wantedSynchronizable: Bool
    ) -> Bool {
        // Nothing stored under this id yet, so there is nothing to rewrite.
        guard let currentSynchronizable else { return false }
        if currentSynchronizable != wantedSynchronizable { return true }
        // Device-only items written before this rule existed still carry the
        // older, backup-migratable class. Refresh those once, then leave them be.
        if !wantedSynchronizable, currentAccessibility != .afterFirstUnlockThisDeviceOnly {
            return true
        }
        return false
    }
}

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

    /// The accessibility class of the stored item, or `nil` when no item is
    /// stored. Lets a migration tell a device-only item that already has the
    /// device-only class from one written before that rule existed, so it only
    /// rewrites the latter.
    func accessibility(for id: UUID) throws -> CredentialAccessibility?

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
