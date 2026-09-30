import CairnCore
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct AlertsSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SystemSurfaceCoordinator.enabledKey) private var enabled = false
    @AppStorage(SystemSurfaceCoordinator.connectionsKey) private var connections = true
    @AppStorage(SystemSurfaceCoordinator.forecastKey) private var forecast = true
    @AppStorage(SystemSurfaceCoordinator.commitmentsKey) private var commitments = true
    @AppStorage(SystemSurfaceCoordinator.appLockEnabledKey) private var appLockEnabled = false
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var isRequesting = false

    private var preferences: String { "\(enabled):\(connections):\(forecast):\(commitments)" }

    var body: some View {
        Section {
            Toggle("Cairn Alerts", isOn: Binding(
                get: { enabled },
                set: { value in
                    if !value { enabled = false; return }
                    isRequesting = true
                    Task {
                        _ = await SystemSurfaceCoordinator.requestAuthorizationAndSchedule(for: model)
                        await updateAuthorization()
                        isRequesting = false
                    }
                }
            ))
            .disabled(isRequesting)
            if enabled {
                Toggle("Connection health", isOn: $connections)
                Toggle("Forecast shortfalls", isOn: $forecast)
                Toggle("Bills and income plans", isOn: $commitments)
                Text("Plan reminders arrive a day before they are due. Changed and past-due plans also get an alert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Send Test Alert", systemImage: "bell.badge") {
                    Task {
                        do {
                            try await SystemSurfaceCoordinator.sendTestAlert()
                            // swiftlint:disable:next line_length
                            model.banner = String(localized: "A test alert will arrive in a few seconds. Tap it to open your forecast.")
                        } catch {
                            // swiftlint:disable:next line_length
                            model.banner = String(localized: "Couldn’t send the test alert. Check notification permissions in Settings.")
                        }
                    }
                }
                .disabled(appLockEnabled || authorization == .denied)
            }
            if authorization == .denied {
                Text("Notifications are blocked in system settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Notification Settings") { openSettings() }
            }
            if appLockEnabled {
                Text("Alerts and widgets are paused while Require unlock to open is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Alerts")
        } footer: {
            // swiftlint:disable:next line_length
            Text("Alerts show no amounts or merchant names. Tap an alert to open the relevant forecast, connection, or plan. Each unresolved event alerts once.")
        }
        .task { await updateAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await updateAuthorization() } }
        }
        .onChange(of: preferences) { _, _ in
            Task { await model.refreshSystemSurfaces() }
        }
    }

    private func updateAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func openSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #else
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
        #endif
    }
}
