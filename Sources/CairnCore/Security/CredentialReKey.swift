import Foundation

/// Moves a SimpleFIN Access URL from a credential that a repair merged away to
/// the credential that survived.
///
/// The write happens first and the old item is deleted only after it succeeds,
/// so a Keychain failure can never leave a device with no copy of a working
/// Access URL. Setup tokens are single-use, so losing the only copy is
/// unrecoverable without a new one.
public enum CredentialReKey {
    /// Moves a secret only when the survivor has no copy. Distinct secrets are
    /// both kept for explicit recovery, even when one fetched more recently.
    /// Identical copies may be collapsed. Returns true when the old item was removed.
    @discardableResult
    public static func move(
        store: any CredentialStore,
        from old: UUID,
        to new: UUID,
        synchronizable: Bool
    ) throws -> Bool {
        guard old != new else { return false }
        guard let oldSecret = try store.secret(for: old) else { return false }
        guard let oldOrigin = SimpleFINServerOrigin.normalized(oldSecret) else {
            throw SimpleFINError.connectionConflict
        }

        let newSecret = try store.secret(for: new)
        if let newSecret {
            guard oldOrigin == SimpleFINServerOrigin.normalized(newSecret) else {
                throw SimpleFINError.connectionConflict
            }
            guard oldSecret == newSecret else { return false }
        } else {
            try store.store(oldSecret, id: new, synchronizable: synchronizable)
        }
        try store.delete(id: old)
        return true
    }

    /// One retirement's log line, and the failure when the re-key threw.
    public struct ReKeyResult: Sendable, Equatable {
        public let retired: UUID
        public let message: String
        /// Non-nil when the store rejected the move; the old copy stays.
        public let failure: String?

        public init(retired: UUID, message: String, failure: String? = nil) {
            self.retired = retired
            self.message = message
            self.failure = failure
        }
    }

    /// Handles every retirement, most-duplicated first for stable logs.
    ///
    /// With `dryRun` (`-cairn-skip-credential-rekey`) neither the store nor the
    /// Keychain is read, written, or deleted: each result describes the policy
    /// without predicting which secrets this device holds. Store failures are
    /// reported per credential so one bad item never stops the rest.
    public static func reKey(
        retirements: [UUID: SyncEngine.CredentialRetirement],
        store: any CredentialStore,
        synchronizable: Bool,
        dryRun: Bool
    ) -> [ReKeyResult] {
        retirements
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { retired, retirement in
                if dryRun {
                    return ReKeyResult(
                        retired: retired,
                        message: "Skipped credential re-key: would fill a missing survivor copy; "
                            + "distinct existing secrets are both kept. retired=\(shortID(retired)) "
                            + "survivor=\(shortID(retirement.survivorCredentialID))."
                    )
                }
                do {
                    let moved = try move(
                        store: store,
                        from: retired,
                        to: retirement.survivorCredentialID,
                        synchronizable: synchronizable
                    )
                    return ReKeyResult(
                        retired: retired,
                        message: moved
                            ? "Re-keyed merged credential \(shortID(retired)) -> "
                                + "\(shortID(retirement.survivorCredentialID))."
                            : "No credential changed for retired connection \(shortID(retired))."
                    )
                } catch {
                    return ReKeyResult(
                        retired: retired,
                        message: "",
                        failure: "Could not re-key credential \(shortID(retired)); leaving the old copy."
                    )
                }
            }
    }

    /// A short, opaque stand-in for a credential id, safe to log.
    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
