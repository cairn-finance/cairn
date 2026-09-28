import Foundation
import SwiftData
import CairnCore

enum IntentBridgeError: LocalizedError {
    case appUnavailable
    case storeUnavailable
    case privacyProtected
    case noConnection
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .appUnavailable:
            return String(localized: "Open Cairn before using this action.")
        case .storeUnavailable:
            return String(localized: "Cairn’s data store is unavailable. Open Cairn to repair it.")
        case .privacyProtected:
            return String(localized: "Cairn is locked, so this action is unavailable.")
        case .noConnection:
            return String(localized: "Cairn has no connected bank to sync yet.")
        case let .syncFailed(message):
            return String(localized: "Cairn could not finish syncing: \(message)")
        }
    }
}

/// Connects App Intents to the running `AppModel` without turning the model
/// into a global. The app registers its model when its window appears; intents
/// run only when that model is available, so failures are reported instead of
/// being mistaken for a successful background request.
@MainActor
final class IntentBridge {
    static let shared = IntentBridge()

    private weak var model: AppModel?
    private init() {}

    func register(_ model: AppModel) {
        self.model = model
    }

    func requestSync() async throws -> AppModel.SyncState {
        guard let model else { throw IntentBridgeError.appUnavailable }
        guard model.storeFailure == nil else { throw IntentBridgeError.storeUnavailable }
        guard !UserDefaults.standard.bool(forKey: AppModel.Keys.appLockEnabled) else {
            throw IntentBridgeError.privacyProtected
        }

        let state = await model.syncAll(force: true)
        switch state {
        case .success:
            return state
        case .idle:
            throw IntentBridgeError.noConnection
        case let .failed(message):
            throw IntentBridgeError.syncFailed(message)
        case let .waiting(title, detail, _):
            throw IntentBridgeError.syncFailed("\(title): \(detail)")
        case .syncing:
            throw IntentBridgeError.syncFailed(String(localized: "Sync is still running."))
        }
    }

    func pendingReviewCount() throws -> Int {
        guard let model else { throw IntentBridgeError.appUnavailable }
        guard model.storeFailure == nil else { throw IntentBridgeError.storeUnavailable }
        guard !UserDefaults.standard.bool(forKey: AppModel.Keys.appLockEnabled) else {
            throw IntentBridgeError.privacyProtected
        }
        let transactions = try model.container.mainContext.fetch(FetchDescriptor<LedgerTransaction>())
        return ReviewInboxItem.items(from: transactions.map { $0.rowValue() }).count
    }

    func forecastSummary() async throws -> String {
        guard let model else { throw IntentBridgeError.appUnavailable }
        guard model.storeFailure == nil else { throw IntentBridgeError.storeUnavailable }
        guard !UserDefaults.standard.bool(forKey: AppModel.Keys.appLockEnabled) else {
            throw IntentBridgeError.privacyProtected
        }
        let forecast = try await model.engine.forecast()
        let snapshot = SystemSurfaceSnapshotBuilder.make(forecast: forecast, lastSuccessfulSync: nil)
        guard snapshot.status != .unavailable else {
            return String(localized: "Cairn’s forecast is not available yet.")
        }
        return "Forecast status: \(snapshot.statusLabel). Exact amounts stay in Cairn."
    }
}
