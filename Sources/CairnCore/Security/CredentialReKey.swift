import Foundation

/// Moves a SimpleFIN Access URL from a credential that a repair merged away to
/// the credential that survived.
///
/// The write happens first and the old item is deleted only after it succeeds,
/// so a Keychain failure can never leave a device with no copy of a working
/// Access URL. Setup tokens are single-use, so losing the only copy is
/// unrecoverable without a new one.
public enum CredentialReKey {
    /// Re-stores the secret worth keeping under `new` and deletes the old item.
    /// Returns `true` when the old item was removed.
    ///
    /// When both ids hold a secret, the copy belonging to the credential whose
    /// institutions fetched most recently wins, so a stale Access URL never
    /// replaces a working one. The fetch dates are read before the merge,
    /// because the merged-away rows are gone by the time this runs. On a tie,
    /// or when neither credential ever fetched, the survivor keeps its own copy.
    @discardableResult
    public static func move(
        store: any CredentialStore,
        from old: UUID,
        to new: UUID,
        synchronizable: Bool,
        retiredLastSuccessfulFetch: Date? = nil,
        survivorLastSuccessfulFetch: Date? = nil
    ) throws -> Bool {
        guard old != new else { return false }
        guard let oldSecret = try store.secret(for: old) else { return false }

        let newSecret = try store.secret(for: new)
        if newSecret == nil || isFresher(retiredLastSuccessfulFetch, than: survivorLastSuccessfulFetch) {
            try store.store(oldSecret, id: new, synchronizable: synchronizable)
        }
        try store.delete(id: old)
        return true
    }

    /// Whether the retired credential's secret should replace the survivor's.
    /// A credential that never fetched loses to one that has; between two dates
    /// the newer wins; on a tie the survivor keeps its own copy.
    public static func isFresher(_ retired: Date?, than survivor: Date?) -> Bool {
        guard let retired else { return false }
        guard let survivor else { return true }
        return retired > survivor
    }
}
