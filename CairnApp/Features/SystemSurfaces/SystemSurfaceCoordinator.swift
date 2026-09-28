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
    static let appLockEnabledKey = "cairn.appLockEnabled"

    static var sharedDefaults: UserDefaults? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String,
              !identifier.isEmpty,
              !identifier.hasPrefix("$(") else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    static func refresh(for model: AppModel) async {
        guard !UserDefaults.standard.bool(forKey: appLockEnabledKey) else {
            await clear()
            return
        }
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

    /// Removes all Cairn-owned system-surface state without touching unrelated
    /// app-group data or notifications scheduled by another feature.
    static func clear() async {
        sharedDefaults?.removeObject(forKey: snapshotKey)
        UserDefaults.standard.removeObject(forKey: notificationSignatureKey)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "CairnStatusWidget")
        #endif
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let identifiers = Set(pending
            .map(\.identifier)
            .filter(isOwnedNotificationIdentifier))
            .union(delivered.map(\.request.identifier).filter(isOwnedNotificationIdentifier))
        if !identifiers.isEmpty {
            let values = Array(identifiers)
            center.removePendingNotificationRequests(withIdentifiers: values)
            center.removeDeliveredNotifications(withIdentifiers: values)
        }
        #endif
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
        let plan = SystemNotificationPlanner.plan(
            snapshot: snapshot,
            lastSuccessfulSync: lastSuccessfulSync,
            commitments: commitments,
            now: now
        )
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let ownedPendingIDs = Set(
            pending.map(\.identifier).filter(isOwnedNotificationIdentifier)
        )
        let ownedDeliveredIDs = Set(
            delivered.map(\.request.identifier).filter(isOwnedNotificationIdentifier)
        )
        let signature = plan.map {
            "\($0.identifier):\($0.kind.rawValue):\($0.date?.timeIntervalSince1970 ?? -1)"
        }.joined(separator: "|")
        let desiredIDs = Set(plan.map(\.identifier))
        if signature == UserDefaults.standard.string(forKey: notificationSignatureKey),
           ownedPendingIDs == desiredIDs {
            return
        }

        if !ownedPendingIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(ownedPendingIDs))
        }
        let staleDeliveredIDs = ownedDeliveredIDs.subtracting(desiredIDs)
        if !staleDeliveredIDs.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: Array(staleDeliveredIDs))
        }
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
            do {
                try await center.add(request)
            } catch {
                // Do not record a successful signature when any request failed;
                // the next refresh must retry the complete desired schedule.
                UserDefaults.standard.removeObject(forKey: notificationSignatureKey)
                return
            }
        }
        UserDefaults.standard.set(signature, forKey: notificationSignatureKey)
    }

    private static func isOwnedNotificationIdentifier(_ identifier: String) -> Bool {
        identifier == "cairn.stale-connection"
            || identifier == "cairn.forecast-risk"
            || identifier.hasPrefix("cairn.commitment.")
    }
    #endif
}

extension AppModel {
    func refreshSystemSurfaces() async {
        await SystemSurfaceCoordinator.refresh(for: self)
    }
}
