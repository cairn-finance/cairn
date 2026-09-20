import Foundation

extension AppModel {
    /// True when the device has no usable network path. Used to explain that a
    /// sync did not fail — it is waiting for a connection.
    var isOffline: Bool { connectivity.isOnline == false }

    /// The calm explanation shown in place of a raw sync error while offline.
    /// Cached data keeps working, so this is not a failure.
    var offlineSyncExplanation: String {
        "You’re offline, so Cairn can’t reach your bank right now. Your saved data still works, "
            + "and sync resumes on its own when you’re back online."
    }

    /// Whether the last sync problem is explained by the device being offline.
    /// Callers use this to soften a failure into a paused state.
    var syncProblemIsJustOffline: Bool {
        guard isOffline else { return false }
        if case .failed = syncState { return true }
        return false
    }
}
