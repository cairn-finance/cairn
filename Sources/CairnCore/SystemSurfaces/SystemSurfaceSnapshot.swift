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
    public let nextCommitmentDate: Date?

    public init(
        status: Status, currencyCode: String? = nil, asOf: Date? = nil,
        generatedAt: Date = .now, nextCommitmentDate: Date? = nil
    ) {
        self.status = status
        self.currencyCode = currencyCode
        self.asOf = asOf
        self.generatedAt = generatedAt
        self.nextCommitmentDate = nextCommitmentDate
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
        commitments: [SystemSurfaceCommitment] = [],
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
            generatedAt: now,
            nextCommitmentDate: commitments
                .filter { $0.status == .upcoming || $0.status == .due }
                .map(\.dueDate).min()
        )
    }
}

public struct SystemNotification: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case staleConnection
        case budgetRisk
        case upcomingCommitment
        case dueCommitment
        case missedCommitment
        case changedCommitment
    }

    public let identifier: String
    public let kind: Kind
    public let title: String
    public let body: String
    public let date: Date?
    public let destination: SystemSurfaceDestination
    public let eventKey: String

    public init(
        identifier: String, kind: Kind, title: String, body: String, date: Date? = nil,
        destination: SystemSurfaceDestination = .forecast, eventKey: String? = nil
    ) {
        self.identifier = identifier
        self.kind = kind
        self.title = title
        self.body = body
        self.date = date
        self.destination = destination
        self.eventKey = eventKey ?? "\(identifier):\(kind.rawValue)"
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
        upcomingWindow: TimeInterval = 7 * 24 * 60 * 60,
        enabledKinds: Set<SystemNotification.Kind> = Set(SystemNotification.Kind.allCases)
    ) -> [SystemNotification] {
        var result: [SystemNotification] = []
        if let lastSuccessfulSync {
            let staleDate = lastSuccessfulSync.addingTimeInterval(staleAfter)
            result.append(SystemNotification(
                identifier: "cairn.stale-connection",
                kind: .staleConnection,
                title: String(localized: "Cairn connection needs attention"),
                body: String(localized: "Your connection has not synced recently. Tap to check connection health and retry."),
                date: staleDate > now ? staleDate : nil,
                destination: .connections,
                eventKey: "stale:\(lastSuccessfulSync.timeIntervalSince1970)"
            ))
        }
        if snapshot.status == .needsAttention {
            result.append(SystemNotification(
                identifier: "cairn.forecast-risk",
                kind: .budgetRisk,
                title: String(localized: "Cairn forecast needs attention"),
                // swiftlint:disable:next line_length
                body: String(localized: "Your saved balances and confirmed plans forecast a shortfall. Tap to see the next 30 days."),
                destination: .forecast
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
                title = String(localized: "A confirmed plan is due soon")
                body = String(localized: "A bill or income plan is due within a day. Tap to check its date and expected amount.")
            case .due:
                kind = .dueCommitment
                title = String(localized: "A confirmed plan is due today")
                body = String(localized: "Tap to check the bill or income plan due today. Bank settlement may arrive later.")
            case .changed:
                kind = .changedCommitment
                title = String(localized: "A confirmed plan has changed")
                // swiftlint:disable:next line_length
                body = String(localized: "An observed payment differs from its saved plan. Tap to review the expected amount and schedule.")
            default:
                kind = .missedCommitment
                title = String(localized: "A confirmed plan is past due")
                // swiftlint:disable:next line_length
                body = String(localized: "Cairn has not matched a payment to a past-due plan. Tap to check it; synced data may be incomplete.")
            }
            let reminderDate = commitment.dueDate.addingTimeInterval(-24 * 60 * 60)
            result.append(SystemNotification(
                identifier: "cairn.commitment.\(commitment.id)",
                kind: kind,
                title: title,
                body: body,
                date: isUpcoming && reminderDate > now ? reminderDate : nil,
                destination: UUID(uuidString: commitment.id).map(SystemSurfaceDestination.commitment) ?? .commitments,
                eventKey: "\(kind.rawValue):\(commitment.dueDate.timeIntervalSince1970)"
            ))
        }
        // Leave headroom below the system's pending-request limit. Prefer the
        // nearest actionable events when there are many confirmed plans.
        return result.filter { enabledKinds.contains($0.kind) }.enumerated().sorted {
            let first = $0.element.date ?? now
            let second = $1.element.date ?? now
            return first == second ? $0.offset < $1.offset : first < second
        }.prefix(60).map(\.element)
    }
}

/// Remembers successfully scheduled events, including alerts the person has
/// dismissed. A refresh must not re-alert for the same unresolved state.
public enum SystemNotificationSchedule {
    public static func requests(
        plan: [SystemNotification],
        pendingEvents: [String: String],
        recordedEvents: [String: String]
    ) -> [SystemNotification] {
        plan.filter { item in
            if let pending = pendingEvents[item.identifier] { return pending != item.eventKey }
            return recordedEvents[item.identifier] != item.eventKey
        }
    }
}
