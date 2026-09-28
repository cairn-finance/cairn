import Foundation

/// Privacy-safe data written for system surfaces. It contains no merchant,
/// account, institution, credential, or transaction data.
public struct SystemSurfaceSnapshot: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case onTrack
        case review
        case needsAttention
        case unavailable
    }

    public let status: Status
    public let currencyCode: String?
    public let asOf: Date?
    public let generatedAt: Date

    public init(status: Status, currencyCode: String? = nil, asOf: Date? = nil, generatedAt: Date = .now) {
        self.status = status
        self.currencyCode = currencyCode
        self.asOf = asOf
        self.generatedAt = generatedAt
    }

    public var statusLabel: String {
        switch status {
        case .onTrack: "On track"
        case .review: "Review forecast"
        case .needsAttention: "Needs attention"
        case .unavailable: "Not available"
        }
    }
}

/// Builds the aggregate status used by the widget and notification scheduler.
/// Exact balances intentionally never leave this pure value boundary.
public enum SystemSurfaceSnapshotBuilder {
    public static func make(
        forecast: [ForecastBalance],
        lastSuccessfulSync: Date?,
        now: Date = .now
    ) -> SystemSurfaceSnapshot {
        guard let first = forecast.first else {
            return SystemSurfaceSnapshot(status: .unavailable, asOf: lastSuccessfulSync, generatedAt: now)
        }

        let currency = first.currency.code
        let points = forecast.filter { $0.currency.code == currency }
        let minimum = points.map(\.balanceMinorUnits).min() ?? 0
        let uncertain = points.contains(where: \.uncertainty)
        let status: SystemSurfaceSnapshot.Status
        if minimum < 0 {
            status = .needsAttention
        } else if uncertain {
            status = .review
        } else {
            status = .onTrack
        }
        return SystemSurfaceSnapshot(
            status: status,
            currencyCode: currency,
            asOf: lastSuccessfulSync,
            generatedAt: now
        )
    }
}

public struct SystemNotification: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case staleConnection
        case budgetRisk
        case upcomingCommitment
        case missedCommitment
    }

    public let identifier: String
    public let kind: Kind
    public let title: String
    public let body: String
    public let date: Date?

    public init(identifier: String, kind: Kind, title: String, body: String, date: Date? = nil) {
        self.identifier = identifier
        self.kind = kind
        self.title = title
        self.body = body
        self.date = date
    }
}

public struct SystemSurfaceCommitment: Equatable, Sendable {
    public let id: String
    public let status: CommitmentStatus
    public let dueDate: Date

    public init(id: String, status: CommitmentStatus, dueDate: Date) {
        self.id = id
        self.status = status
        self.dueDate = dueDate
    }
}

/// Produces at most one notification for each actionable state. Identifiers
/// are stable, so the platform scheduler can replace requests idempotently.
public enum SystemNotificationPlanner {
    public static func plan(
        snapshot: SystemSurfaceSnapshot,
        lastSuccessfulSync: Date?,
        commitments: [(id: String, status: CommitmentStatus, dueDate: Date)],
        now: Date = .now,
        staleAfter: TimeInterval = 36 * 60 * 60
    ) -> [SystemNotification] {
        var result: [SystemNotification] = []
        if let lastSuccessfulSync, now.timeIntervalSince(lastSuccessfulSync) > staleAfter {
            result.append(SystemNotification(
                identifier: "cairn.stale-connection",
                kind: .staleConnection,
                title: "Cairn connection needs attention",
                body: "Stored financial data may be out of date. Open Cairn to review connection health."
            ))
        }
        if snapshot.status == .needsAttention {
            result.append(SystemNotification(
                identifier: "cairn.forecast-risk",
                kind: .budgetRisk,
                title: "Cairn forecast needs attention",
                body: "A confirmed commitment may take the forecast below zero. Review the forecast in Cairn."
            ))
        }
        for commitment in commitments where commitment.status == .upcoming || commitment.status == .missed || commitment.status == .changed {
            let kind: SystemNotification.Kind = commitment.status == .upcoming ? .upcomingCommitment : .missedCommitment
            let title = commitment.status == .upcoming ? "Upcoming confirmed commitment" : "Confirmed commitment changed"
            result.append(SystemNotification(
                identifier: "cairn.commitment.\(commitment.id)",
                kind: kind,
                title: title,
                body: commitment.status == .upcoming
                    ? "A confirmed commitment is coming up. Open Cairn to review it."
                    : "A confirmed commitment needs review in Cairn.",
                date: commitment.status == .upcoming ? commitment.dueDate : nil
            ))
        }
        return result
    }
}
