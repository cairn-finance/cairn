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

    /// Which local copy a re-key would keep.
    public enum Kept: String, Sendable, Equatable {
        case survivor
        case retired
    }

    /// The freshness decision for one retirement, with the reason to show.
    public struct Preview: Sendable, Equatable {
        public let kept: Kept
        public let reason: String

        public init(kept: Kept, reason: String) {
            self.kept = kept
            self.reason = reason
        }
    }

    /// Decides which copy a re-key would keep from the fetch dates the repair
    /// recorded. Reads nothing from the credential store, so it is safe on a
    /// device whose Keychain must be left alone.
    ///
    /// The decision is the freshness rule alone. When the survivor holds no
    /// copy the real re-key still writes the retired secret whatever this says,
    /// but that cannot be known without reading, which a preview must not do.
    public static func preview(
        retiredLastSuccessfulFetch: Date?,
        survivorLastSuccessfulFetch: Date?
    ) -> Preview {
        if isFresher(retiredLastSuccessfulFetch, than: survivorLastSuccessfulFetch) {
            let reason = survivorLastSuccessfulFetch == nil
                ? "the survivor’s credential has never fetched"
                : "the retired credential fetched more recently"
            return Preview(kept: .retired, reason: reason)
        }
        let reason: String
        switch (retiredLastSuccessfulFetch, survivorLastSuccessfulFetch) {
        case (nil, nil):
            reason = "neither credential has fetched"
        case (nil, _):
            reason = "the retired credential has never fetched"
        default:
            reason = "the survivor’s credential fetched at least as recently"
        }
        return Preview(kept: .survivor, reason: reason)
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
    /// Keychain is read, written, or deleted: each result only describes the
    /// copy that would be kept and why. Otherwise each retirement is moved, and
    /// a store failure is reported per credential so one bad item never stops
    /// the rest.
    public static func reKey(
        retirements: [UUID: SyncEngine.CredentialRetirement],
        store: any CredentialStore,
        synchronizable: Bool,
        dryRun: Bool
    ) -> [ReKeyResult] {
        retirements
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { retired, retirement in
                let preview = preview(
                    retiredLastSuccessfulFetch: retirement.retiredLastSuccessfulFetch,
                    survivorLastSuccessfulFetch: retirement.survivorLastSuccessfulFetch
                )
                if dryRun {
                    let keptID = preview.kept == .retired ? retired : retirement.survivorCredentialID
                    return ReKeyResult(
                        retired: retired,
                        message: "Skipped credential re-key: would keep the \(preview.kept.rawValue) secret "
                            + "(\(shortID(keptID))); retired=\(shortID(retired)) "
                            + "survivor=\(shortID(retirement.survivorCredentialID)); \(preview.reason)."
                    )
                }
                do {
                    let moved = try move(
                        store: store,
                        from: retired,
                        to: retirement.survivorCredentialID,
                        synchronizable: synchronizable,
                        retiredLastSuccessfulFetch: retirement.retiredLastSuccessfulFetch,
                        survivorLastSuccessfulFetch: retirement.survivorLastSuccessfulFetch
                    )
                    return ReKeyResult(
                        retired: retired,
                        message: moved
                            ? "Re-keyed merged credential \(shortID(retired)) -> "
                                + "\(shortID(retirement.survivorCredentialID))."
                            : "No stored copy to re-key for credential \(shortID(retired))."
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
