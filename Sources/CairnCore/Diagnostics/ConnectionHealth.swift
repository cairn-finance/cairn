import Foundation

/// The small, value-only input used to describe a saved connection's freshness.
/// It intentionally contains no Access URL or credential material.
public struct ConnectionHealthSnapshot: Sendable, Equatable {
    public var lastSuccessfulSync: Date?
    public var lastTransactionDate: Date?
    public var requestsRemaining: Int
    public var hasPendingTransactions: Bool
    public var errorMessage: String?
    public var hasCredential: Bool
    public var isOffline: Bool
    public var isSyncing: Bool

    public init(
        lastSuccessfulSync: Date? = nil,
        lastTransactionDate: Date? = nil,
        requestsRemaining: Int = 0,
        hasPendingTransactions: Bool = false,
        errorMessage: String? = nil,
        hasCredential: Bool = true,
        isOffline: Bool = false,
        isSyncing: Bool = false
    ) {
        self.lastSuccessfulSync = lastSuccessfulSync
        self.lastTransactionDate = lastTransactionDate
        self.requestsRemaining = requestsRemaining
        self.hasPendingTransactions = hasPendingTransactions
        self.errorMessage = errorMessage
        self.hasCredential = hasCredential
        self.isOffline = isOffline
        self.isSyncing = isSyncing
    }
}

public enum ConnectionHealthStatus: String, Sendable, Equatable {
    case healthy
    case stale
    case failed
    case limited
    case pending
    case offline
    case reconnect
}

/// Applies stable, user-facing precedence to connection facts. The UI can use
/// the result without duplicating freshness or request-limit rules.
public enum ConnectionHealthEvaluator {
    public static let defaultStaleAfter: TimeInterval = 36 * 60 * 60

    public static func status(
        for snapshot: ConnectionHealthSnapshot,
        now: Date,
        staleAfter: TimeInterval = defaultStaleAfter
    ) -> ConnectionHealthStatus {
        guard snapshot.hasCredential else { return .reconnect }
        if snapshot.isOffline { return .offline }
        if let error = snapshot.errorMessage, !error.isEmpty { return .failed }
        if snapshot.requestsRemaining <= 0 { return .limited }
        if snapshot.isSyncing { return .pending }
        guard let lastSync = snapshot.lastSuccessfulSync,
              now.timeIntervalSince(lastSync) <= staleAfter else { return .stale }
        return .healthy
    }
}
