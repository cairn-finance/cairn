import SwiftUI
import UserNotifications
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

    init() {
        UNUserNotificationCenter.current().delegate = CairnNotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if model.storeFailure != nil {
                    StoreUnavailableView()
                } else {
                    LockGate {
                        RootView()
                    }
                    .modelContainer(model.container)
                }
            }
            .environment(model)
            .onOpenURL { SystemSurfaceRouter.shared.open($0) }
            .task {
                IntentBridge.shared.register(model)
                await model.refreshSystemSurfaces()
            }
            .onChange(of: scenePhase) { _, phase in
                #if os(iOS)
                // Never schedule a background pass against a store that failed
                // to open.
                if phase == .background, model.storeFailure == nil {
                    BackgroundCategorization.schedule(requiresPower: model.categorizeOnlyWhileCharging)
                }
                #endif
                if phase == .active, model.storeFailure == nil {
                    Task { await model.refreshSystemSurfaces() }
                }
            }
        }
        #if os(macOS)
        Settings {
            Group {
                if model.storeFailure != nil {
                    StoreUnavailableView()
                } else {
                    LockGate {
                        SettingsView()
                    }
                    .modelContainer(model.container)
                }
            }
            .environment(model)
        }
        #endif
    }
}
