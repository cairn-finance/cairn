import SwiftUI
#if os(iOS)
import UIKit
#endif

#if os(iOS)
/// Registers the background categorization task before launch finishes, which
/// is the only window in which `BGTaskScheduler` accepts a registration.
final class CairnAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PowerSource.prepare()
        BackgroundCategorization.register()
        return true
    }
}
#endif

@main
struct CairnApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @UIApplicationDelegateAdaptor(CairnAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            LockGate {
                RootView()
            }
            .environment(model)
            .modelContainer(model.container)
            .onChange(of: scenePhase) { _, phase in
                #if os(iOS)
                // Hand the bulk of the backlog to a background task when the app
                // leaves the foreground, waiting for a charger if asked.
                if phase == .background {
                    BackgroundCategorization.schedule(requiresPower: model.categorizeOnlyWhileCharging)
                }
                #endif
            }
        }
        #if os(macOS)
        Settings {
            LockGate {
                SettingsView()
            }
            .environment(model)
            .modelContainer(model.container)
        }
        #endif
    }
}
