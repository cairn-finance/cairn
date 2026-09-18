import Foundation
import Testing
@testable import CairnCore

/// Credential migration must be idempotent and quiet: rewriting a synced item
/// pushes a new revision through iCloud Keychain to every other device, so it
/// can only happen when the stored item actually differs. It also has to reason
/// about the two copies separately, because both exist at once after switching
/// modes.
@Suite("Credential migration")
struct CredentialMigrationTests {
    @Test("A credential that already matches is left alone")
    func matchingCredentialIsNotRewritten() {
        #expect(
            !CredentialMigration.needsRewrite(
                wantedSynchronizable: true,
                deviceOnlyAccessibility: nil,
                syncedAccessibility: .afterFirstUnlock
            )
        )
        #expect(
            !CredentialMigration.needsRewrite(
                wantedSynchronizable: false,
                deviceOnlyAccessibility: .afterFirstUnlockThisDeviceOnly,
                syncedAccessibility: nil
            )
        )
    }

    @Test("Both copies at once settle in either mode")
    func bothCopiesAreLeftAlone() {
        // The state switching from iCloud to This Device Only leaves behind: the
        // local copy is what reads use, and the iCloud copy stays for the other
        // devices. Neither mode has anything to do.
        #expect(
            !CredentialMigration.needsRewrite(
                wantedSynchronizable: false,
                deviceOnlyAccessibility: .afterFirstUnlockThisDeviceOnly,
                syncedAccessibility: .afterFirstUnlock
            )
        )
        #expect(
            !CredentialMigration.needsRewrite(
                wantedSynchronizable: true,
                deviceOnlyAccessibility: .afterFirstUnlockThisDeviceOnly,
                syncedAccessibility: .afterFirstUnlock
            )
        )
    }

    @Test("A changed sync setting is rewritten")
    func changedModeIsRewritten() {
        // Local → iCloud: there is no iCloud copy yet.
        #expect(
            CredentialMigration.needsRewrite(
                wantedSynchronizable: true,
                deviceOnlyAccessibility: .afterFirstUnlockThisDeviceOnly,
                syncedAccessibility: nil
            )
        )
        // iCloud → local: there is no local copy yet.
        #expect(
            CredentialMigration.needsRewrite(
                wantedSynchronizable: false,
                deviceOnlyAccessibility: nil,
                syncedAccessibility: .afterFirstUnlock
            )
        )
    }

    @Test("A device-only credential from an older build is upgraded once")
    func legacyDeviceOnlyIsUpgraded() {
        // Before the device-only rule, a local credential was written with the
        // migratable class, so it could ride along in a backup.
        #expect(
            CredentialMigration.needsRewrite(
                wantedSynchronizable: false,
                deviceOnlyAccessibility: .afterFirstUnlock,
                syncedAccessibility: nil
            )
        )
        #expect(
            CredentialMigration.needsRewrite(
                wantedSynchronizable: false,
                deviceOnlyAccessibility: .other,
                syncedAccessibility: nil
            )
        )
    }

    @Test("A missing copy of the wanted mode is written")
    func missingCopyIsWritten() {
        // The caller only asks once it has read a secret, so at least one copy
        // exists. "No copy of the wanted mode" therefore means one has to be
        // created: either the mode changed, or an older build only ever wrote the
        // other copy.
        #expect(
            CredentialMigration.needsRewrite(
                wantedSynchronizable: false,
                deviceOnlyAccessibility: nil,
                syncedAccessibility: nil
            )
        )
        #expect(
            CredentialMigration.needsRewrite(
                wantedSynchronizable: true,
                deviceOnlyAccessibility: nil,
                syncedAccessibility: nil
            )
        )
    }

    @Test("The in-memory store reports each copy's class")
    func inMemoryStoreReportsAccessibility() throws {
        let store = InMemoryCredentialStore()
        let id = UUID()

        try store.store("https://demo:demo@example.com/simplefin", id: id, synchronizable: false)
        #expect(try store.accessibility(for: id, synchronizable: false) == .afterFirstUnlockThisDeviceOnly)
        #expect(try store.accessibility(for: id, synchronizable: true) == nil)
        #expect(
            !CredentialMigration.needsRewrite(
                wantedSynchronizable: false,
                deviceOnlyAccessibility: try store.accessibility(for: id, synchronizable: false),
                syncedAccessibility: try store.accessibility(for: id, synchronizable: true)
            )
        )

        // An item written by an older build: device-only by intent, migratable by
        // class. It is rewritten once, and afterwards no longer needs it.
        let legacyID = UUID()
        try store.store(
            "https://demo:demo@example.com/simplefin",
            id: legacyID,
            synchronizable: false,
            accessibility: .afterFirstUnlock
        )
        #expect(
            CredentialMigration.needsRewrite(
                wantedSynchronizable: false,
                deviceOnlyAccessibility: try store.accessibility(for: legacyID, synchronizable: false),
                syncedAccessibility: try store.accessibility(for: legacyID, synchronizable: true)
            )
        )
        try store.store("https://demo:demo@example.com/simplefin", id: legacyID, synchronizable: false)
        #expect(
            !CredentialMigration.needsRewrite(
                wantedSynchronizable: false,
                deviceOnlyAccessibility: try store.accessibility(for: legacyID, synchronizable: false),
                syncedAccessibility: try store.accessibility(for: legacyID, synchronizable: true)
            )
        )

        // Switching to iCloud adds the synced copy and drops this device's own,
        // and a second launch has nothing left to do.
        try store.store("https://demo:demo@example.com/simplefin", id: id, synchronizable: true)
        #expect(try store.accessibility(for: id, synchronizable: true) == .afterFirstUnlock)
        #expect(try store.accessibility(for: id, synchronizable: false) == nil)
        #expect(
            !CredentialMigration.needsRewrite(
                wantedSynchronizable: true,
                deviceOnlyAccessibility: try store.accessibility(for: id, synchronizable: false),
                syncedAccessibility: try store.accessibility(for: id, synchronizable: true)
            )
        )

        // And switching back leaves both copies, with no rewrite on the next
        // launch. This is the case that used to write to the Keychain every time.
        try store.store("https://demo:demo@example.com/simplefin", id: id, synchronizable: false)
        #expect(try store.accessibility(for: id, synchronizable: false) == .afterFirstUnlockThisDeviceOnly)
        #expect(try store.accessibility(for: id, synchronizable: true) == .afterFirstUnlock)
        for _ in 0..<3 {
            #expect(
                !CredentialMigration.needsRewrite(
                    wantedSynchronizable: false,
                    deviceOnlyAccessibility: try store.accessibility(for: id, synchronizable: false),
                    syncedAccessibility: try store.accessibility(for: id, synchronizable: true)
                )
            )
        }
    }
}
