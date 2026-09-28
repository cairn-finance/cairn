import Foundation
import SwiftData
import CairnCore

/// Connects App Intents to the running `AppModel` without turning the model
/// into a global. The app registers its model when its window appears; an
/// intent that runs while the app is open drives the model directly, and one
/// that fires as the app launches leaves a request that the model consumes the
/// moment it registers.
@MainActor
final class IntentBridge {
    static let shared = IntentBridge()

    private weak var model: AppModel?
    private var pendingSync = false

    private init() {}

    func register(_ model: AppModel) {
        self.model = model
        guard pendingSync else { return }
        pendingSync = false
        Task { await model.syncAll(force: true) }
    }

    func requestSync() {
        if let model {
            Task { await model.syncAll(force: true) }
        } else {
            pendingSync = true
        }
    }

    func pendingReviewCount() -> Int {
        guard let model else { return 0 }
        let transactions = (try? model.container.mainContext.fetch(FetchDescriptor<LedgerTransaction>())) ?? []
        return ReviewInboxItem.items(from: transactions.map { $0.rowValue() }).count
    }

    func forecastSummary() async -> String {
        guard let model else { return "Open Cairn to check the forecast." }
        let snapshot = SystemSurfaceSnapshotBuilder.make(forecast: await model.forecast(), lastSuccessfulSync: nil)
        return "Forecast status: \(snapshot.statusLabel). Exact amounts stay in Cairn."
    }
}
