import Foundation

/// Stable identity of one SimpleFIN connection: the connection id together with
/// the organization it belongs to.
///
/// A display name is never part of the identity. The same bank can be renamed,
/// and two logins at one organization can share a name, so names are unusable
/// for matching. The organization id disambiguates two organizations that reuse
/// a connection id, and the pair is stable across devices and credentials.
public struct ConnectionIdentity: Hashable, Sendable {
    public let connectionID: String
    public let organizationID: String

    public init(connectionID: String, organizationID: String) {
        self.connectionID = connectionID
        self.organizationID = organizationID
    }

    /// The identity of a connection, or `nil` for a credential holder (no
    /// connection id) or a connection SimpleFIN did not identify.
    public static func of(connectionID: String, organizationID: String) -> ConnectionIdentity? {
        guard !connectionID.isEmpty else { return nil }
        return ConnectionIdentity(connectionID: connectionID, organizationID: organizationID)
    }
}

/// What a newly claimed or reconnected Access URL should attach to, decided from
/// the connection identities already stored.
public enum ConnectionAdoption: Sendable, Equatable {
    /// No stored connection matches, so this is a separate SimpleFIN user. It
    /// gets its own credential and holder, as before.
    case fresh
    /// Every known connection belongs to one stored credential. The new Access
    /// URL is stored under that credential and no new holder is created.
    case adopt(credentialID: UUID)
    /// The known connections belong to more than one stored credential. Do not
    /// guess which to adopt: keep the rows as they are and report it.
    case ambiguous(credentialIDs: [UUID])
}

/// Matches incoming connections against what is stored, across every credential.
public enum ConnectionMatcher {
    /// One stored connection, as the matcher sees it.
    public struct StoredConnection: Sendable, Equatable {
        public let identity: ConnectionIdentity
        public let credentialID: UUID

        public init(identity: ConnectionIdentity, credentialID: UUID) {
            self.identity = identity
            self.credentialID = credentialID
        }
    }

    /// Decides how a claimed token's connections map onto stored ones.
    ///
    /// Only connections with a usable identity participate; a connection the
    /// server did not identify can never match and so is treated as new.
    public static func decide(
        incoming: [SimpleFINConnection],
        stored: [StoredConnection]
    ) -> ConnectionAdoption {
        let storedIdentities = stored.map(\.identity)

        var matched: Set<UUID> = []
        for connection in incoming {
            guard let identity = ConnectionIdentity.of(
                connectionID: connection.id,
                organizationID: connection.organizationID
            ) else { continue }
            let matches = Set(matchingIdentities(identity, stored: storedIdentities))
            for row in stored where matches.contains(row.identity) {
                matched.insert(row.credentialID)
            }
        }

        if matched.isEmpty { return .fresh }
        if matched.count == 1, let only = matched.first {
            return .adopt(credentialID: only)
        }
        return .ambiguous(credentialIDs: matched.sorted { $0.uuidString < $1.uuidString })
    }

    /// The stored identities an incoming connection matches. An exact identity
    /// match wins; otherwise a stored row whose organization id is empty
    /// matches on the connection id alone, but only when it is the only stored
    /// row with that connection id. A row saved before the organization id was
    /// recorded has no other way to match, and guessing among several rows with
    /// the same connection id would attach the data to the wrong bank.
    public static func matchingIdentities(
        _ incoming: ConnectionIdentity,
        stored: [ConnectionIdentity]
    ) -> [ConnectionIdentity] {
        let exact = stored.filter { $0 == incoming }
        if !exact.isEmpty { return exact }
        let sameConnectionID = stored.filter { $0.connectionID == incoming.connectionID }
        guard sameConnectionID.count == 1,
              let only = sameConnectionID.first,
              only.organizationID.isEmpty else { return [] }
        return [only]
    }

    /// Credentials whose connections are also held by another credential, so a
    /// repair will merge them or has merged them. The recovery scan and the
    /// "can't sync yet" notice use this to avoid offering Reconnect or Remove
    /// for a row that is about to disappear.
    public static func redundantCredentialIDs(stored: [StoredConnection]) -> Set<UUID> {
        var redundant: Set<UUID> = []
        for credentials in credentialsByIdentity(stored).values where credentials.count > 1 {
            redundant.formUnion(credentials)
        }
        return redundant
    }

    private static func credentialsByIdentity(
        _ stored: [StoredConnection]
    ) -> [ConnectionIdentity: Set<UUID>] {
        var result: [ConnectionIdentity: Set<UUID>] = [:]
        for connection in stored {
            result[connection.identity, default: []].insert(connection.credentialID)
        }
        return result
    }
}

/// Chooses which institution survives when one connection is stored more than
/// once.
///
/// The rule reads only values that sync: `createdAt` (`Institution.createdAt`)
/// and `credentialID`. Neither depends on which Keychain item a device happens
/// to hold, so two devices repairing the same duplicates at the same time keep
/// the same row. When the candidates tie on every stored value the choice is
/// indeterminate and the repair leaves them alone rather than let two devices
/// delete each other's survivor.
public enum ConnectionSurvivor {
    public struct Candidate: Sendable, Equatable {
        public let credentialID: UUID
        public let createdAt: Date

        public init(credentialID: UUID, createdAt: Date) {
            self.credentialID = credentialID
            self.createdAt = createdAt
        }
    }

    /// Index of the survivor, or `nil` when the list is empty or the top
    /// candidates are indistinguishable.
    public static func choose(_ candidates: [Candidate]) -> Int? {
        guard !candidates.isEmpty else { return nil }

        var best = 0
        for index in candidates.indices.dropFirst()
        where isPreferred(candidates[index], over: candidates[best]) {
            best = index
        }

        let tied = candidates.indices.contains { index in
            index != best
                && candidates[index].createdAt == candidates[best].createdAt
                && candidates[index].credentialID == candidates[best].credentialID
        }
        return tied ? nil : best
    }

    /// Earlier `createdAt` wins; ties break on the credential id's string order.
    public static func isPreferred(_ lhs: Candidate, over rhs: Candidate) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.credentialID.uuidString < rhs.credentialID.uuidString
    }
}