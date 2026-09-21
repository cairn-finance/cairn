import Foundation
import Network
import Observation

/// Watches the network so the app can explain that sync is paused rather than
/// showing a failure that looks like a broken connection. When the path is
/// unsatisfied the device is offline; everything already synced still works.
@MainActor
@Observable
final class NetworkMonitor {
    /// True while a usable network path exists. Optimistic before the first
    /// update so the UI never flashes an offline warning on launch.
    private(set) var isOnline = true

    /// Called after the path transitions from offline to online, so the app can
    /// resume a sync the network interrupted.
    @ObservationIgnored var onBecameOnline: (() -> Void)?

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "app.cairn.network-monitor")
    @ObservationIgnored private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOnline = self.isOnline
                self.isOnline = online
                if !wasOnline, online {
                    self.onBecameOnline?()
                }
            }
        }
        monitor.start(queue: queue)
    }

    nonisolated deinit {
        monitor.cancel()
    }
}
