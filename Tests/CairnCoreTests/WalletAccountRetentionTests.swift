import Foundation
import Testing
@testable import CairnCore

@Suite("Wallet account retention")
struct WalletAccountRetentionTests {
    @Test("A temporarily empty result deletes nothing")
    func emptyResultIsNeverDestructive() {
        let removed = WalletAccountRetention.keysToRemove(
            previouslySeen: ["wallet-A", "wallet-B"],
            currentlySeen: [],
            storedKeys: ["wallet-A", "wallet-B"]
        )
        #expect(removed.isEmpty)
    }

    @Test("A device never removes accounts it has never seen")
    func otherDevicesAccountsAreLeftAlone() {
        // This device has only ever seen wallet-A; wallet-B belongs to another
        // device that is authorized for a different card.
        let removed = WalletAccountRetention.keysToRemove(
            previouslySeen: ["wallet-A"],
            currentlySeen: ["wallet-A"],
            storedKeys: ["wallet-A", "wallet-B"]
        )
        #expect(removed.isEmpty)
    }

    @Test("An account this device saw and no longer sees is removed")
    func genuinelyGoneAccountsAreRemoved() {
        let removed = WalletAccountRetention.keysToRemove(
            previouslySeen: ["wallet-A", "wallet-B"],
            currentlySeen: ["wallet-A"],
            storedKeys: ["wallet-A", "wallet-B"]
        )
        #expect(removed == ["wallet-B"])
    }

    @Test("A key that is no longer stored locally is not reported")
    func alreadyDeletedKeysAreIgnored() {
        let removed = WalletAccountRetention.keysToRemove(
            previouslySeen: ["wallet-A", "wallet-B"],
            currentlySeen: ["wallet-A"],
            storedKeys: ["wallet-A"]
        )
        #expect(removed.isEmpty)
    }

    @Test("A first sync on a new device deletes nothing")
    func firstSyncIsHarmless() {
        let removed = WalletAccountRetention.keysToRemove(
            previouslySeen: [],
            currentlySeen: ["wallet-A", "wallet-B"],
            storedKeys: ["wallet-A", "wallet-B"]
        )
        #expect(removed.isEmpty)
    }
}
