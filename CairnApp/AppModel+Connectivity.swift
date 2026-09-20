import Foundation

extension AppModel {
    /// True when the device has no usable network path. Used to explain that a
    /// sync did not fail — it is waiting for a connection.
    var isOffline: Bool { connectivity.isOnline == false }

    /// The calm explanation shown in place of a raw sync error while offline.
    /// Cached data keeps working, so this is not a failure.
    var offlineSyncExplanation: String {
        String(
            localized: "You’re offline, so Cairn can’t reach your bank right now. Your saved data still works, and sync resumes on its own when you’re back online."
        )
    }

    /// Whether the last sync problem is explained by the device being offline.
    /// Callers use this to soften a failure into a paused state.
    var syncProblemIsJustOffline: Bool {
        guard isOffline else { return false }
        if case .failed = syncState { return true }
        return false
    }

    /// Resumes a sync the network interrupted. Called when reachability comes
    /// back, so the copy promising an automatic resume is actually wired. Only
    /// a pass that ended in a failure is resumed, and never a second pass while
    /// one is already in flight, so a flapping path cannot pile up syncs.
    func resumeSyncAfterReconnect() {
        guard storeFailure == nil, !isResumingAfterReconnect, syncState != .syncing else { return }
        guard case .failed = syncState else { return }
        isResumingAfterReconnect = true
        Task { [weak self] in
            guard let self else { return }
            await self.syncAll(force: false)
            self.isResumingAfterReconnect = false
        }
    }
}
