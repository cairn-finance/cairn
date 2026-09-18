import Foundation

/// Decides whether the Keychain holds a SimpleFIN credential that no
/// `Institution` references, which means it can be rebuilt without a new setup
/// token.
///
/// A credential is orphaned when the database is gone but the Keychain item is
/// not. That happens after deleting and reinstalling on iOS (Keychain survives,
/// the store and UserDefaults do not), after a store that could not be opened is
/// started over, or on a new device with iCloud Keychain on but iCloud Sync off.
public enum CredentialRecovery {
    public enum Decision: Sendable, Equatable {
        /// Nothing to offer: no credential is orphaned, or the institution set
        /// has not settled yet.
        case none
        /// These credentials have no institution and can be rebuilt from their
        /// stored Access URLs.
        case offer(credentialIDs: [UUID])
    }

    /// - Parameters:
    ///   - storedCredentialIDs: every credential id the Keychain holds, across
    ///     both synchronizable and device-only copies.
    ///   - institutionCredentialIDs: the credential id of every `Institution`
    ///     row, including the connection-less holder that `listedAsBanks` hides.
    ///     A credential referenced by any row is not orphaned.
    ///   - institutionsReady: whether the initial store import has settled. With
    ///     iCloud Sync on, an `Institution` can arrive a few seconds after
    ///     launch; until then a missing row proves nothing, so nothing is offered
    ///     that might be rebuilt just before it syncs in.
    public static func decide(
        storedCredentialIDs: [UUID],
        institutionCredentialIDs: [UUID],
        institutionsReady: Bool
    ) -> Decision {
        guard institutionsReady else { return .none }
        let known = Set(institutionCredentialIDs)
        let orphans = storedCredentialIDs.filter { !known.contains($0) }
        return orphans.isEmpty ? .none : .offer(credentialIDs: orphans)
    }
}
