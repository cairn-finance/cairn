import Foundation

/// Moves a SimpleFIN Access URL from a credential that a repair merged away to
/// the credential that survived.
///
/// The write happens first and the old item is deleted only after it succeeds,
/// so a Keychain failure can never leave a device with no copy of a working
/// Access URL. Setup tokens are single-use, so losing the only copy is
/// unrecoverable without a new one.
public enum CredentialReKey {
    /// Re-stores `old`'s secret under `new` and deletes the old item. Returns
    /// `true` when the old item was removed.
    ///
    /// When `new` already holds a secret there is nothing to copy, and the old
    /// item is still deleted afterwards: the survivor is what the merged
    /// institution now reads.
    @discardableResult
    public static func move(
        store: any CredentialStore,
        from old: UUID,
        to new: UUID,
        synchronizable: Bool
    ) throws -> Bool {
        guard old != new else { return false }
        guard let secret = try store.secret(for: old) else { return false }

        if try store.secret(for: new) == nil {
            try store.store(secret, id: new, synchronizable: synchronizable)
        }
        try store.delete(id: old)
        return true
    }
}