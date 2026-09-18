import Foundation
#if os(iOS)
import UIKit
#endif

/// Reads the device's power situation so the on-device model can be paused when
/// it would be wasteful. Kept in the app target because the reading is
/// platform-specific; the decision itself lives in `CategorizationPower`.
///
/// `UIDevice` is main-actor-isolated, and every caller already runs there
/// (`AppModel` and the app delegate), so the reads are declared main-actor too
/// rather than crossing an isolation boundary to touch them.
@MainActor
enum PowerSource {
    #if os(iOS)
    static func prepare() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// True when charging or full. An unknown state (for example the simulator)
    /// is treated as external power so a foreground pass is never blocked by a
    /// reading the device can't provide.
    static var isOnExternalPower: Bool {
        switch UIDevice.current.batteryState {
        case .unplugged: false
        case .charging, .full: true
        case .unknown: true
        @unknown default: true
        }
    }
    #else
    static func prepare() {}

    /// A Mac's battery is not modeled here; the bulk pass is allowed unless the
    /// person restricts it, and thermal and Low Power Mode still apply.
    static var isOnExternalPower: Bool { true }
    #endif
}
