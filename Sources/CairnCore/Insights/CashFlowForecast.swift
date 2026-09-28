import Foundation

public enum CommitmentState: String, Codable, CaseIterable, Sendable {
    case active, paused, canceled
}

public enum CommitmentStatus: String, Codable, Sendable {
    case upcoming, due, paid, changed, missed, uncertain
}

public enum CommitmentStatusEvaluator {
    public static func status(nextDueDate: Date, now: Date = .now, lastObservedDate: Date? = nil, expectedAmount: Int64 = 0, observedAmount: Int64? = nil, uncertain: Bool = false, calendar: Calendar = .current) -> CommitmentStatus {
        if uncertain { return .uncertain }
        if let observedAmount, observedAmount != expectedAmount { return .changed }
        if let lastObservedDate, calendar.isDate(lastObservedDate, inSameDayAs: nextDueDate) || lastObservedDate > nextDueDate { return .paid }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: nextDueDate)).day ?? 0
        if days < 0 { return .missed }
        if days == 0 { return .due }
        return .upcoming
    }
}

public struct ForecastBalance: Sendable, Equatable {
    public let date: Date
    public let balanceMinorUnits: Int64
    public let currency: Currency
    public let uncertainty: Bool
    public init(date: Date, balanceMinorUnits: Int64, currency: Currency, uncertainty: Bool = false) {
        self.date = date; self.balanceMinorUnits = balanceMinorUnits; self.currency = currency; self.uncertainty = uncertainty
    }
}

public struct ForecastAccount: Sendable, Equatable {
    public let balanceMinorUnits: Int64
    public let currency: Currency
    public let asOf: Date?
    public init(balanceMinorUnits: Int64, currency: Currency, asOf: Date? = nil) {
        self.balanceMinorUnits = balanceMinorUnits; self.currency = currency; self.asOf = asOf
    }
}

/// A scenario, not a promise. It applies confirmed entries on their due dates
/// and never converts between currencies.
public enum CashFlowForecast {
    public static func balances(
        accounts: [ForecastAccount], commitments: [ConfirmedCommitmentValue],
        through days: Int = 30, now: Date = .now, calendar: Calendar = .current,
        staleAfter: TimeInterval = 48 * 60 * 60
    ) -> [ForecastBalance] {
        let grouped = Dictionary(grouping: accounts, by: { $0.currency.code })
        return grouped.values.flatMap { (accounts: [ForecastAccount]) -> [ForecastBalance] in
            guard let currency = accounts.first?.currency else { return [] }
            var balance = accounts.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.balanceMinorUnits) }
            var result: [ForecastBalance] = []
            for offset in 0...max(0, days) {
                let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) ?? now
                if offset > 0 {
                    for item in commitments {
                        if Self.isDue(item, currency: currency, date: date, calendar: calendar, now: now) {
                            balance = MinorUnits.addClamped(balance, item.amountMinorUnits)
                        }
                    }
                }
                let stale = accounts.contains { Self.isStale($0, now: now, threshold: staleAfter) }
                let hasUncertainCommitment = commitments.contains { Self.isUncertain($0, currency: currency) }
                let uncertain = stale || hasUncertainCommitment
                let point = ForecastBalance(date: date, balanceMinorUnits: balance, currency: currency, uncertainty: uncertain)
                result.append(point)
            }
            return result
        }.sorted { $0.currency.code == $1.currency.code ? $0.date < $1.date : $0.currency.code < $1.currency.code }
    }

    private static func isStale(_ account: ForecastAccount, now: Date, threshold: TimeInterval) -> Bool {
        guard let asOf = account.asOf else { return true }
        return now.timeIntervalSince(asOf) > threshold
    }

    private static func isDue(_ item: ConfirmedCommitmentValue, currency: Currency, date: Date, calendar: Calendar, now: Date) -> Bool {
        guard item.currency.code == currency.code, item.state == .active else { return false }
        var occurrence = item.nextDueDate
        let start = calendar.startOfDay(for: now)
        while occurrence < start {
            guard let next = calendar.date(byAdding: .day, value: max(1, Int(item.cadence.approximateDays.rounded())), to: occurrence) else { return false }
            occurrence = next
        }
        return calendar.isDate(occurrence, inSameDayAs: date)
    }

    private static func isUncertain(_ item: ConfirmedCommitmentValue, currency: Currency) -> Bool {
        item.currency.code == currency.code && item.state == .active && item.uncertain
    }
}

public struct ConfirmedCommitmentValue: Sendable, Equatable {
    public let amountMinorUnits: Int64
    public let currency: Currency
    public let cadence: RecurringCadence
    public let nextDueDate: Date
    public let state: CommitmentState
    public let uncertain: Bool
    public init(amountMinorUnits: Int64, currency: Currency = .usd, cadence: RecurringCadence = .monthly, nextDueDate: Date, state: CommitmentState = .active, uncertain: Bool = false) {
        self.amountMinorUnits = amountMinorUnits; self.currency = currency; self.cadence = cadence; self.nextDueDate = nextDueDate; self.state = state; self.uncertain = uncertain
    }
}
