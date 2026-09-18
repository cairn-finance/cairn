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
    ///
    /// Each copy is asked about separately, because both can exist at once: after
    /// switching from iCloud to This Device Only the device-only copy is added and
    /// the iCloud copy is deliberately left in place for the other devices. A
    /// lookup that ignores synchronizability returns whichever copy it happens to
    /// match, which would make the local copy look wrong — and rewrite it — on
    /// every launch.
    public static func needsRewrite(
        wantedSynchronizable: Bool,
        deviceOnlyAccessibility: CredentialAccessibility?,
        syncedAccessibility: CredentialAccessibility?
    ) -> Bool {
        if wantedSynchronizable {
            // One iCloud copy is all this mode wants, and iCloud Keychain fixes
            // its accessibility class.
            return syncedAccessibility == nil
        }
        // Device-only mode wants a local copy that cannot ride along in a backup.
        // A device-only item written before that rule existed still carries the
        // older, migratable class: refresh those once, then leave them be.
        return deviceOnlyAccessibility != .afterFirstUnlockThisDeviceOnly
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

    /// The accessibility class of the copy with the given synchronizability, or
    /// `nil` when that copy is not stored.
    ///
    /// Lets a migration tell a device-only copy that already has the device-only
    /// class from one written before that rule existed, without having to guess
    /// which of the two copies a lookup would return.
    func accessibility(for id: UUID, synchronizable: Bool) throws -> CredentialAccessibility?

    /// Every credential id held, across both synchronizable and device-only
    /// copies. A credential whose database row is gone can then be offered for
    /// reconnection instead of forcing a new setup token.
    func allIDs() throws -> [UUID]

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
