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
        case .onTrack: String(localized: "On track")
        case .review: String(localized: "Review forecast")
        case .needsAttention: String(localized: "Needs attention")
        case .unavailable: String(localized: "Not available")
        }
    }

    /// Prevents a system surface from presenting an old financial state when
    /// the app has not refreshed its local snapshot for a long time.
    public func isFresh(at now: Date = .now, maximumAge: TimeInterval = 26 * 60 * 60) -> Bool {
        let age = now.timeIntervalSince(generatedAt)
        return age >= 0 && age <= maximumAge
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
        guard !forecast.isEmpty else {
            return SystemSurfaceSnapshot(status: .unavailable, asOf: lastSuccessfulSync, generatedAt: now)
        }

        let minimumByCurrency = Dictionary(grouping: forecast, by: \.currency)
            .values
            .map { $0.map(\.balanceMinorUnits).min() ?? 0 }
        let minimumIsNegative = minimumByCurrency.contains { $0 < 0 }
        let uncertain = forecast.contains(where: \.uncertainty)
        let currencies = Set(forecast.map(\.currency))
        let status: SystemSurfaceSnapshot.Status
        if minimumIsNegative {
            status = .needsAttention
        } else if uncertain {
            status = .review
        } else {
            status = .onTrack
        }
        return SystemSurfaceSnapshot(
            status: status,
            currencyCode: currencies.count == 1 ? currencies.first?.code : nil,
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
        case changedCommitment
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
        commitments: [SystemSurfaceCommitment],
        now: Date = .now,
        staleAfter: TimeInterval = 36 * 60 * 60,
        upcomingWindow: TimeInterval = 7 * 24 * 60 * 60
    ) -> [SystemNotification] {
        var result: [SystemNotification] = []
        if let lastSuccessfulSync, now.timeIntervalSince(lastSuccessfulSync) > staleAfter {
            result.append(SystemNotification(
                identifier: "cairn.stale-connection",
                kind: .staleConnection,
                title: String(localized: "Cairn connection needs attention"),
                body: String(localized: "Stored financial data may be out of date. Open Cairn to review connection health.")
            ))
        }
        if snapshot.status == .needsAttention {
            result.append(SystemNotification(
                identifier: "cairn.forecast-risk",
                kind: .budgetRisk,
                title: String(localized: "Cairn forecast needs attention"),
                body: String(localized: "A confirmed commitment may take the forecast below zero. Review the forecast in Cairn.")
            ))
        }
        for commitment in commitments {
            let isUpcoming = commitment.status == .upcoming
                && commitment.dueDate.timeIntervalSince(now) >= 0
                && commitment.dueDate.timeIntervalSince(now) <= upcomingWindow
            let isDue = commitment.status == .due
            let isActionable = isUpcoming || isDue || commitment.status == .missed || commitment.status == .changed
            guard isActionable else { continue }

            let kind: SystemNotification.Kind
            let title: String
            let body: String
            switch commitment.status {
            case .upcoming:
                kind = .upcomingCommitment
                title = String(localized: "Upcoming confirmed commitment")
                body = String(localized: "A confirmed commitment is coming up. Open Cairn to review it.")
            case .due:
                kind = .upcomingCommitment
                title = String(localized: "Confirmed commitment due today")
                body = String(localized: "A confirmed commitment is due today. Open Cairn to review it.")
            case .changed:
                kind = .changedCommitment
                title = String(localized: "Confirmed commitment changed")
                body = String(localized: "A confirmed commitment needs review in Cairn.")
            default:
                kind = .missedCommitment
                title = String(localized: "Confirmed commitment missed")
                body = String(localized: "A confirmed commitment needs review in Cairn.")
            }
            result.append(SystemNotification(
                identifier: "cairn.commitment.\(commitment.id)",
                kind: kind,
                title: title,
                body: body,
                date: isUpcoming && commitment.dueDate > now ? commitment.dueDate : nil
            ))
        }
        return result
    }
}
