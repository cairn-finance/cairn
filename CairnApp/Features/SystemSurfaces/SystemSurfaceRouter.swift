import CairnCore
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class SystemSurfaceRouter {
    static let shared = SystemSurfaceRouter()

    struct Request: Identifiable {
        let id = UUID()
        let destination: SystemSurfaceDestination
    }

    var pending: Request?

    func open(_ url: URL) {
        guard let destination = SystemSurfaceDestination(url: url) else { return }
        pending = Request(destination: destination)
    }
}

/// Retained for the app lifetime and installed before launch completes.
final class CairnNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = CairnNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        // UIKit may perform presentation work from the completion callback.
        // Keep the callback itself on the main actor, not just our UI changes.
        Task { @MainActor in
            completionHandler([.banner, .list, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let content = response.notification.request.content
        let destination = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? (content.userInfo[SystemSurfaceCoordinator.routeKey] as? String)
            .flatMap(URL.init(string:)).flatMap(SystemSurfaceDestination.init(url:))
            ?? SystemSurfaceDestination.legacyNotification(identifier: response.notification.request.identifier)
            : nil
        // Use the explicit callback API so the system's response completion
        // cannot return through the nonisolated async delegate bridge.
        Task { @MainActor in
            if let destination {
                SystemSurfaceRouter.shared.pending = .init(destination: destination)
            }
            completionHandler()
        }
    }
}
