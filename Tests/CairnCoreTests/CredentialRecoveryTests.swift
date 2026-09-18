import Foundation
import Testing
@testable import CairnCore

/// Recovering an orphaned SimpleFIN credential: the Keychain can outlive the
/// database (delete-and-reinstall, a store that could not be opened, a new device
/// with iCloud Keychain on but iCloud Sync off), and a working Access URL should
/// not have to be thrown away for a new setup token.
@Suite("Credential recovery")
struct CredentialRecoveryTests {
    @Test("The in-memory store lists every credential once, both copies")
    func inMemoryStoreListsIDs() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.allIDs().isEmpty)

        let synced = UUID()
        let deviceOnly = UUID()
        try store.store("https://a.example/simplefin", id: synced, synchronizable: true)
        try store.store("https://b.example/simplefin", id: deviceOnly, synchronizable: false)
        #expect(Set(try store.allIDs()) == Set([synced, deviceOnly]))

        // Both copies of one id collapse to a single entry.
        try store.store("https://a.example/simplefin", id: synced, synchronizable: false)
        #expect(try store.accessibility(for: synced, synchronizable: true) == .afterFirstUnlock)
        #expect(try store.accessibility(for: synced, synchronizable: false) == .afterFirstUnlockThisDeviceOnly)
        #expect(try store.allIDs().filter { $0 == synced }.count == 1)
    }

    @Test("A credential no institution references is offered for reconnection")
    func orphanedCredentialIsOffered() {
        let orphan = UUID()
        let known = UUID()
        let decision = CredentialRecovery.decide(
            storedCredentialIDs: [orphan, known],
            institutionCredentialIDs: [known],
            institutionsReady: true
        )
        #expect(decision == .offer(credentialIDs: [orphan]))
    }

    @Test("A credential referenced by the hidden holder is not orphaned")
    func holderCredentialIsNotOrphaned() {
        // `Institution.listedAsBanks` hides a connection-less credential holder,
        // but it is still an institution row, so its credential must never be
        // offered for a rebuild.
        let held = UUID()
        let decision = CredentialRecovery.decide(
            storedCredentialIDs: [held],
            institutionCredentialIDs: [held],
            institutionsReady: true
        )
        #expect(decision == .none)
    }

    @Test("Nothing is offered before the institution set has settled")
    func waitsForICloudArrival() {
        let arriving = UUID()
        // Before the initial import lands, the row is missing but nothing may be
        // offered: the credential is about to sync in.
        #expect(
            CredentialRecovery.decide(
                storedCredentialIDs: [arriving],
                institutionCredentialIDs: [],
                institutionsReady: false
            ) == .none
        )
        // Once it arrives it belongs to an institution, so still nothing.
        #expect(
            CredentialRecovery.decide(
                storedCredentialIDs: [arriving],
                institutionCredentialIDs: [arriving],
                institutionsReady: true
            ) == .none
        )
    }

    @Test("With nothing stored, nothing is offered")
    func noCredentials() {
        #expect(
            CredentialRecovery.decide(
                storedCredentialIDs: [],
                institutionCredentialIDs: [UUID()],
                institutionsReady: true
            ) == .none
        )
    }
}