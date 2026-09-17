import Foundation
import Testing
@testable import CairnCore

/// Credential migration must be idempotent and quiet: rewriting a synced item
/// pushes a new revision through iCloud Keychain to every other device, so it
/// can only happen when the stored item actually differs.
@Suite("Credential migration")
struct CredentialMigrationTests {
    @Test("A credential that already matches is left alone")
    func matchingCredentialIsNotRewritten() {
        #expect(
            !CredentialMigration.needsRewrite(
                currentSynchronizable: true,
                currentAccessibility: .afterFirstUnlock,
                wantedSynchronizable: true
            )
        )
        #expect(
            !CredentialMigration.needsRewrite(
                currentSynchronizable: false,
                currentAccessibility: .afterFirstUnlockThisDeviceOnly,
                wantedSynchronizable: false
            )
        )
    }

    @Test("A changed sync setting is rewritten")
    func changedModeIsRewritten() {
        #expect(
            CredentialMigration.needsRewrite(
                currentSynchronizable: true,
                currentAccessibility: .afterFirstUnlock,
                wantedSynchronizable: false
            )
        )
        #expect(
            CredentialMigration.needsRewrite(
                currentSynchronizable: false,
                currentAccessibility: .afterFirstUnlockThisDeviceOnly,
                wantedSynchronizable: true
            )
        )
    }

    @Test("A device-only credential from an older build is upgraded once")
    func legacyDeviceOnlyIsUpgraded() {
        // Before the device-only rule, a local credential was written with the
        // migratable class, so it could ride along in a backup.
        #expect(
            CredentialMigration.needsRewrite(
                currentSynchronizable: false,
                currentAccessibility: .afterFirstUnlock,
                wantedSynchronizable: false
            )
        )
        #expect(
            CredentialMigration.needsRewrite(
                currentSynchronizable: false,
                currentAccessibility: .other,
                wantedSynchronizable: false
            )
        )
    }

    @Test("Nothing stored means nothing to rewrite")
    func missingItemIsNotRewritten() {
        #expect(
            !CredentialMigration.needsRewrite(
                currentSynchronizable: nil,
                currentAccessibility: nil,
                wantedSynchronizable: false
            )
        )
    }

    @Test("The in-memory store reports the class the decision reads")
    func inMemoryStoreReportsAccessibility() throws {
        let store = InMemoryCredentialStore()
        let id = UUID()

        try store.store("https://demo:demo@example.com/simplefin", id: id, synchronizable: false)
        #expect(try store.accessibility(for: id) == .afterFirstUnlockThisDeviceOnly)
        #expect(
            !CredentialMigration.needsRewrite(
                currentSynchronizable: try store.isSynchronizable(for: id),
                currentAccessibility: try store.accessibility(for: id),
                wantedSynchronizable: false
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
                currentSynchronizable: try store.isSynchronizable(for: legacyID),
                currentAccessibility: try store.accessibility(for: legacyID),
                wantedSynchronizable: false
            )
        )
        try store.store("https://demo:demo@example.com/simplefin", id: legacyID, synchronizable: false)
        #expect(
            !CredentialMigration.needsRewrite(
                currentSynchronizable: try store.isSynchronizable(for: legacyID),
                currentAccessibility: try store.accessibility(for: legacyID),
                wantedSynchronizable: false
            )
        )

        // Switching to iCloud is a real change, and device-only items are gone
        // once they are synced, so repeats settle too.
        try store.store("https://demo:demo@example.com/simplefin", id: id, synchronizable: true)
        #expect(try store.accessibility(for: id) == .afterFirstUnlock)
        #expect(
            !CredentialMigration.needsRewrite(
                currentSynchronizable: try store.isSynchronizable(for: id),
                currentAccessibility: try store.accessibility(for: id),
                wantedSynchronizable: true
            )
        )
    }
}
