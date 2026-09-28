import Foundation
import Testing
@testable import CairnCore

@Suite("Connection health")
struct ConnectionHealthTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("Missing credentials take priority over other connection facts")
    func missingCredentialNeedsReconnect() {
        let snapshot = ConnectionHealthSnapshot(
            lastSuccessfulSync: now,
            requestsRemaining: 24,
            errorMessage: "old error",
            hasCredential: false
        )

        #expect(ConnectionHealthEvaluator.status(for: snapshot, now: now) == .reconnect)
    }

    @Test("Errors and exhausted request budgets are visible")
    func failuresAndLimits() {
        let failed = ConnectionHealthSnapshot(lastSuccessfulSync: now, requestsRemaining: 4, errorMessage: "Bridge unavailable")
        let limited = ConnectionHealthSnapshot(lastSuccessfulSync: now, requestsRemaining: 0)

        #expect(ConnectionHealthEvaluator.status(for: failed, now: now) == .failed)
        #expect(ConnectionHealthEvaluator.status(for: limited, now: now) == .limited)
    }

    @Test("A connection becomes stale without implying real-time data")
    func staleAndHealthy() {
        let fresh = ConnectionHealthSnapshot(lastSuccessfulSync: now, requestsRemaining: 1)
        let old = ConnectionHealthSnapshot(lastSuccessfulSync: now.addingTimeInterval(-37 * 60 * 60), requestsRemaining: 1)

        #expect(ConnectionHealthEvaluator.status(for: fresh, now: now) == .healthy)
        #expect(ConnectionHealthEvaluator.status(for: old, now: now) == .stale)
        #expect(ConnectionHealthEvaluator.status(for: ConnectionHealthSnapshot(requestsRemaining: 1), now: now) == .stale)
    }

    @Test("Offline and in-flight states are distinct")
    func transientStates() {
        let offline = ConnectionHealthSnapshot(lastSuccessfulSync: now, requestsRemaining: 1, isOffline: true)
        let syncing = ConnectionHealthSnapshot(lastSuccessfulSync: now, requestsRemaining: 1, isSyncing: true)

        #expect(ConnectionHealthEvaluator.status(for: offline, now: now) == .offline)
        #expect(ConnectionHealthEvaluator.status(for: syncing, now: now) == .pending)
    }
}
