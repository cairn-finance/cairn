import AppIntents
import Foundation

/// Syncs Cairn from Siri, Shortcuts, or Spotlight.
///
/// It brings the app forward first so the sync engine and the Keychain
/// credential it needs are ready, then asks `IntentBridge` to run a pass. The
/// work itself is the same `syncAll` the in-app Sync button uses.
struct SyncCairnIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Cairn"

    static let description = IntentDescription(
        "Fetch the latest balances and transactions from your connected banks."
    )

    static var supportedModes: IntentModes { .foreground(.immediate) }

    func perform() async throws -> some IntentResult {
        await MainActor.run { IntentBridge.shared.requestSync() }
        return .result()
    }
}

/// The phrase Siri and Shortcuts offer for Cairn.
struct CairnShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncCairnIntent(),
            phrases: ["Sync \(.applicationName)"],
            shortTitle: "Sync Cairn",
            systemImageName: "arrow.clockwise"
        )
    }
}
