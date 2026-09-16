import Foundation

/// Decides which mirrored Apple Wallet accounts a device may delete after a
/// sync.
///
/// Wallet rows live in the same store that syncs through iCloud, while
/// FinanceKit authorization is per device. Deleting every account the current
/// device doesn't report is destructive: another device can be authorized for
/// different cards, and a temporarily empty result would cascade-delete
/// transactions, notes, and tags through iCloud on every device.
///
/// So removal is scoped to accounts *this* device has successfully seen before
/// and no longer sees. Anything it has never seen belongs to another device and
/// is left alone. Kept free of FinanceKit so it can be tested on any platform.
public enum WalletAccountRetention {
    /// Keys this device should delete, given device-local memory of what it saw
    /// last time, what it sees now, and what actually exists locally.
    ///
    /// An empty `currentlySeen` means the query failed or returned nothing
    /// usable — never a reason to delete.
    public static func keysToRemove(
        previouslySeen: Set<String>,
        currentlySeen: Set<String>,
        storedKeys: Set<String>
    ) -> Set<String> {
        guard !currentlySeen.isEmpty else { return [] }
        return previouslySeen.subtracting(currentlySeen).intersection(storedKeys)
    }
}
