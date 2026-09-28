import Foundation
import SwiftData
import CairnCore
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Owns the narrow, aggregate snapshot shared with system surfaces. The app
/// group contains this snapshot only; it is never a SwiftData or Keychain
/// container. A missing group identifier disables sharing safely.
@MainActor
enum SystemSurfaceCoordinator {
    static let snapshotKey = "cairn.system-surface.snapshot"
    static let appGroupInfoKey = "CairnAppGroupIdentifier"
    static let notificationSignatureKey = "cairn.notifications.signature"

    static var sharedDefaults: UserDefaults? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String,
              !identifier.isEmpty,
              !identifier.hasPrefix("$(") else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    static func refresh(for model: AppModel) async {
        let forecasts = await model.forecast(days: 30)
        let institutions = (try? model.container.mainContext.fetch(FetchDescriptor<Institution>())) ?? []
        let lastSync = institutions.compactMap(\.lastSuccessfulFetch).max()
        let snapshot = SystemSurfaceSnapshotBuilder.make(
            forecast: forecasts,
            lastSuccessfulSync: lastSync,
            now: .now
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            sharedDefaults?.set(data, forKey: snapshotKey)
        }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "CairnStatusWidget")
        #endif
        await scheduleNotifications(
            snapshot: snapshot,
            lastSuccessfulSync: lastSync,
            commitments: (try? await model.engine.systemSurfaceCommitments()) ?? []
        )
    }

    #if canImport(UserNotifications)
    static func requestAuthorizationAndSchedule(for model: AppModel) async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard granted else { return false }
            UserDefaults.standard.set(true, forKey: "cairn.notifications.enabled")
            await refresh(for: model)
            return true
        } catch {
            return false
        }
    }

    private static func scheduleNotifications(
        snapshot: SystemSurfaceSnapshot,
        lastSuccessfulSync: Date?,
        commitments: [SystemSurfaceCommitment]
    ) async {
        guard UserDefaults.standard.bool(forKey: "cairn.notifications.enabled") else { return }
        let now = Date.now
        let values = commitments.map { (id: $0.id, status: $0.status, dueDate: $0.dueDate) }
        let plan = SystemNotificationPlanner.plan(
            snapshot: snapshot,
            lastSuccessfulSync: lastSuccessfulSync,
            commitments: values,
            now: now
        )
        let signature = plan.map { "\($0.identifier):\($0.kind.rawValue)" }.joined(separator: "|")
        guard signature != UserDefaults.standard.string(forKey: notificationSignatureKey) else { return }
        UserDefaults.standard.set(signature, forKey: notificationSignatureKey)

        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        for item in plan {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            let trigger: UNNotificationTrigger?
            if let date = item.date, date > now {
                trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: max(60, date.timeIntervalSince(now)),
                    repeats: false
                )
            } else {
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)
            }
            let request = UNNotificationRequest(identifier: item.identifier, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }
    #endif
}

extension AppModel {
    func refreshSystemSurfaces() async {
        await SystemSurfaceCoordinator.refresh(for: self)
    }
}
