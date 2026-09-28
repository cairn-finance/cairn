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
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        _ = try await IntentBridge.shared.requestSync()
        return .result(dialog: "Cairn finished syncing.")
    }
}

/// Reports the review queue without exposing transaction or merchant detail.
struct ReviewPendingItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Review Pending Items"
    static let description = IntentDescription("Tell me how many items need review in Cairn.")
    static var supportedModes: IntentModes { .foreground(.immediate) }
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        let count = try await MainActor.run { try IntentBridge.shared.pendingReviewCount() }
        return .result(dialog: count == 0 ? "Your Cairn review inbox is clear." : "Cairn has \(count) items to review.")
    }
}

/// Reports aggregate forecast status. This is foreground-only because the
/// forecast is derived from the app's local SwiftData store.
struct CheckForecastStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Forecast Status"
    static let description = IntentDescription("Check Cairn's aggregate forecast status without showing exact amounts.")
    static var supportedModes: IntentModes { .foreground(.immediate) }
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        let summary = try await IntentBridge.shared.forecastSummary()
        return .result(dialog: IntentDialog(stringLiteral: summary))
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
        AppShortcut(
            intent: ReviewPendingItemsIntent(),
            phrases: ["Review pending items in \(.applicationName)"],
            shortTitle: "Review pending items",
            systemImageName: "tray.full"
        )
        AppShortcut(
            intent: CheckForecastStatusIntent(),
            phrases: ["Check forecast in \(.applicationName)"],
            shortTitle: "Check forecast",
            systemImageName: "gauge.with.dots.needle.67percent"
        )
    }
}
