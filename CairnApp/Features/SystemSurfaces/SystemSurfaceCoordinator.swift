import Foundation
import SwiftData
import CairnCore
import WidgetKit
import UserNotifications

/// Shares only aggregate status with the widget; the ledger stays in the app.
@MainActor
enum SystemSurfaceCoordinator {
    static let snapshotKey = "cairn.system-surface.snapshot"
    static let financialSnapshotKey = FinancialWidgetSnapshot.sharedDefaultsKey
    static let appGroupInfoKey = "CairnAppGroupIdentifier"
    static let enabledKey = "cairn.notifications.enabled"
    static let connectionsKey = "cairn.notifications.connections"
    static let forecastKey = "cairn.notifications.forecast"
    static let commitmentsKey = "cairn.notifications.commitments"
    static let eventsKey = "cairn.notifications.events"
    nonisolated static let routeKey = "cairn.destination"
    static let eventKey = "cairn.event"
    static let appLockEnabledKey = "cairn.appLockEnabled"
    private static var isRefreshing = false
    private static var refreshAgain = false
    private static var isRefreshingFinancialWidget = false
    private static var refreshFinancialWidgetAgain = false
    private static var financialWidgetRefreshTask: Task<Void, Never>?
    private static var financialWidgetGeneration = 0

    static var sharedDefaults: UserDefaults? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String,
              !identifier.isEmpty, !identifier.hasPrefix("$(") else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    static func refresh(for model: AppModel) async {
        // Scene activation and sync completion can overlap across suspension.
        guard !isRefreshing else { refreshAgain = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            await refreshSnapshot(for: model)
        } while refreshAgain
    }

    private static func refreshSnapshot(for model: AppModel) async {
        guard model.storeFailure == nil,
              !UserDefaults.standard.bool(forKey: appLockEnabledKey) else {
            await clear()
            return
        }
        let forecasts = await model.forecast(days: 30)
        let commitments = (try? await model.engine.systemSurfaceCommitments()) ?? []
        // Privacy may have changed while the actor was fetching values.
        guard !UserDefaults.standard.bool(forKey: appLockEnabledKey), model.storeFailure == nil else {
            await clear()
            return
        }
        let institutions = (try? model.container.mainContext.fetch(FetchDescriptor<Institution>())) ?? []
        // One fresh connection must not mask another stale connection.
        let lastSync = institutions.compactMap(\.lastSuccessfulFetch).min()
        let snapshot = SystemSurfaceSnapshotBuilder.make(
            forecast: forecasts, lastSuccessfulSync: lastSync, commitments: commitments
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            let previous = sharedDefaults?.data(forKey: snapshotKey)
                .flatMap { try? JSONDecoder().decode(SystemSurfaceSnapshot.self, from: $0) }
            sharedDefaults?.set(data, forKey: snapshotKey)
            if previous?.status != snapshot.status || previous?.asOf != snapshot.asOf
                || previous?.nextCommitmentDate != snapshot.nextCommitmentDate
                || previous?.isFresh() != true {
                WidgetCenter.shared.reloadTimelines(ofKind: "CairnStatusWidget")
            }
        }
        await refreshFinancialWidget(for: model)
        await scheduleNotifications(snapshot: snapshot, lastSuccessfulSync: lastSync, commitments: commitments)
    }

    static func scheduleFinancialWidgetRefresh(for model: AppModel) {
        financialWidgetRefreshTask?.cancel()
        financialWidgetRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            await refreshFinancialWidget(for: model)
        }
    }

    private static func refreshFinancialWidget(for model: AppModel) async {
        guard !isRefreshingFinancialWidget else {
            refreshFinancialWidgetAgain = true
            return
        }
        isRefreshingFinancialWidget = true
        defer { isRefreshingFinancialWidget = false }
        repeat {
            refreshFinancialWidgetAgain = false
            await refreshFinancialWidgetSnapshot(for: model)
        } while refreshFinancialWidgetAgain
    }

    private static func refreshFinancialWidgetSnapshot(for model: AppModel) async {
        guard model.storeFailure == nil,
              !UserDefaults.standard.bool(forKey: appLockEnabledKey) else {
            clearFinancialWidgetSnapshot()
            return
        }
        let generation = financialWidgetGeneration
        let container = model.container
        let fetcher = await Task.detached(priority: .utility) {
            FinancialWidgetFetcher(modelContainer: container)
        }.value
        let snapshot = try? await fetcher.snapshot()
        // Do not let a suspended fetch restore private data after lock or deletion.
        guard generation == financialWidgetGeneration,
              !UserDefaults.standard.bool(forKey: appLockEnabledKey),
              model.storeFailure == nil else {
            clearFinancialWidgetSnapshot()
            return
        }
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else {
            clearFinancialWidgetSnapshot()
            return
        }

        let previous = sharedDefaults?.data(forKey: financialSnapshotKey)
            .flatMap { try? JSONDecoder().decode(FinancialWidgetSnapshot.self, from: $0) }
        sharedDefaults?.set(data, forKey: financialSnapshotKey)
        let changed = previous?.netWorth != snapshot.netWorth
            || previous?.primaryCurrency != snapshot.primaryCurrency
            || previous?.monthToDateSpend != snapshot.monthToDateSpend
            || previous?.monthStart != snapshot.monthStart
            || previous?.isFresh() != true
        if changed { reloadFinancialWidgets() }
    }

    private static func clearFinancialWidgetSnapshot() {
        guard sharedDefaults?.object(forKey: financialSnapshotKey) != nil else { return }
        sharedDefaults?.removeObject(forKey: financialSnapshotKey)
        reloadFinancialWidgets()
    }

    static func clear() async {
        financialWidgetGeneration &+= 1
        financialWidgetRefreshTask?.cancel()
        financialWidgetRefreshTask = nil
        sharedDefaults?.removeObject(forKey: snapshotKey)
        sharedDefaults?.removeObject(forKey: financialSnapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: "CairnStatusWidget")
        reloadFinancialWidgets()
        await clearNotifications()
    }

    private static func reloadFinancialWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: "CairnNetWorthWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "CairnMonthToDateSpendWidget")
    }

    static func clearNotifications() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let ids = Set(pending.map(\.identifier).filter(isOwnedNotificationIdentifier))
            .union(delivered.map(\.request.identifier).filter(isOwnedNotificationIdentifier))
        center.removePendingNotificationRequests(withIdentifiers: Array(ids))
        center.removeDeliveredNotifications(withIdentifiers: Array(ids))
        UserDefaults.standard.removeObject(forKey: eventsKey)
        UserDefaults.standard.removeObject(forKey: "cairn.notifications.signature")
    }

    static func requestAuthorizationAndSchedule(for model: AppModel) async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            UserDefaults.standard.set(granted, forKey: enabledKey)
            await refresh(for: model)
            return granted
        } catch {
            return false
        }
    }

    static func sendTestAlert() async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard UserDefaults.standard.bool(forKey: enabledKey),
              settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
              !UserDefaults.standard.bool(forKey: appLockEnabledKey) else {
            throw CocoaError(.userCancelled)
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your Cairn alerts are ready")
        content.body = String(localized: "Tap this test alert to open your cash-flow forecast.")
        content.sound = .default
        content.userInfo = [routeKey: SystemSurfaceDestination.forecast.url.absoluteString]
        try await center.add(UNNotificationRequest(
            identifier: "cairn.test-alert", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        ))
        if !UserDefaults.standard.bool(forKey: enabledKey) || UserDefaults.standard.bool(forKey: appLockEnabledKey) {
            await clearNotifications()
            throw CocoaError(.userCancelled)
        }
    }

    private static func allows(_ kind: SystemNotification.Kind) -> Bool {
        let key: String
        switch kind {
        case .staleConnection: key = connectionsKey
        case .budgetRisk: key = forecastKey
        default: key = commitmentsKey
        }
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private static func scheduleNotifications(
        snapshot: SystemSurfaceSnapshot, lastSuccessfulSync: Date?, commitments: [SystemSurfaceCommitment]
    ) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard UserDefaults.standard.bool(forKey: enabledKey),
              settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
              !UserDefaults.standard.bool(forKey: appLockEnabledKey) else {
            await clearNotifications()
            return
        }
        let now = Date.now
        let plan = SystemNotificationPlanner.plan(
            snapshot: snapshot, lastSuccessfulSync: lastSuccessfulSync, commitments: commitments, now: now,
            enabledKinds: Set(SystemNotification.Kind.allCases.filter { allows($0) })
        )
        let desired = Dictionary(uniqueKeysWithValues: plan.map { ($0.identifier, $0.eventKey) })
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        var records = UserDefaults.standard.dictionary(forKey: eventsKey) as? [String: String] ?? [:]
        var pendingEvents: [String: String] = [:]
        var obsolete: [String] = []
        for request in pending where isOwnedNotificationIdentifier(request.identifier) {
            guard request.identifier != "cairn.test-alert" else { continue }
            let event = request.content.userInfo[eventKey] as? String ?? "legacy"
            if desired[request.identifier] != event { obsolete.append(request.identifier) }
            pendingEvents[request.identifier] = event
        }
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
        var oldDelivered: [String] = []
        for notification in delivered where isOwnedNotificationIdentifier(notification.request.identifier) {
            let request = notification.request
            guard request.identifier != "cairn.test-alert" else { continue }
            guard let wanted = desired[request.identifier] else {
                oldDelivered.append(request.identifier)
                continue
            }
            if let event = request.content.userInfo[eventKey] as? String {
                if event == wanted { records[request.identifier] = event }
                else { oldDelivered.append(request.identifier) }
            } else {
                // Preserve already delivered alerts during the routing upgrade.
                records[request.identifier] = wanted
            }
        }
        center.removeDeliveredNotifications(withIdentifiers: oldDelivered)
        records = records.filter { desired[$0.key] != nil }
        let requests = SystemNotificationSchedule.requests(
            plan: plan, pendingEvents: pendingEvents, recordedEvents: records
        )
        for item in requests {
            // Turning alerts off or enabling the app lock cancels suspended work.
            guard UserDefaults.standard.bool(forKey: enabledKey), allows(item.kind),
                  !UserDefaults.standard.bool(forKey: appLockEnabledKey) else {
                await clearNotifications()
                return
            }
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.threadIdentifier = item.kind == .staleConnection ? "cairn.connections"
                : item.kind == .budgetRisk ? "cairn.forecast" : "cairn.commitments"
            content.userInfo = [routeKey: item.destination.url.absoluteString, eventKey: item.eventKey]
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(60, item.date?.timeIntervalSince(now) ?? 60), repeats: false
            )
            do {
                try await center.add(UNNotificationRequest(identifier: item.identifier, content: content, trigger: trigger))
                guard UserDefaults.standard.bool(forKey: enabledKey),
                      !UserDefaults.standard.bool(forKey: appLockEnabledKey) else {
                    await clearNotifications()
                    return
                }
                records[item.identifier] = item.eventKey
            } catch {
                await cairnLog(.warning, "Could not schedule a Cairn alert: \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.set(records, forKey: eventsKey)
    }

    private static func isOwnedNotificationIdentifier(_ identifier: String) -> Bool {
        SystemSurfaceDestination.legacyNotification(identifier: identifier) != nil
    }
}

extension AppModel {
    func refreshSystemSurfaces() async {
        await SystemSurfaceCoordinator.refresh(for: self)
    }
}
