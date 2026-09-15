import SwiftUI

@main
struct CairnApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            LockGate {
                RootView()
            }
            .environment(model)
            .modelContainer(model.container)
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
