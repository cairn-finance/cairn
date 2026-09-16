import Foundation

/// A transaction reduced to what recurring-payment detection needs, so the
/// detector stays pure and unit-testable without SwiftData. Callers pass
/// transactions for one account; the detector never mixes currencies.
public struct RecurringInput: Sendable, Hashable {
    /// Stable identity of the underlying transaction, used to look it back up.
    public let id: String
    /// Lowercased merchant grouping key.
    public let merchantKey: String
    /// Human-readable merchant name.
    public let displayName: String
    public let amountMinorUnits: Int64
    public let date: Date
    public let accountID: String
    public let accountName: String
    public let currency: Currency
    public let categoryName: String?
    public let categoryColorHex: String?
    public let categorySymbolName: String?
    public let isTransfer: Bool
    public let isIgnored: Bool
    public let isPending: Bool

    public init(
        id: String,
        merchantKey: String,
        displayName: String,
        amountMinorUnits: Int64,
        date: Date,
        accountID: String,
        accountName: String,
        currency: Currency = .usd,
        categoryName: String? = nil,
        categoryColorHex: String? = nil,
        categorySymbolName: String? = nil,
        isTransfer: Bool = false,
        isIgnored: Bool = false,
        isPending: Bool = false
    ) {
        self.id = id
        self.merchantKey = merchantKey
        self.displayName = displayName
        self.amountMinorUnits = amountMinorUnits
        self.date = date
        self.accountID = accountID
        self.accountName = accountName
        self.currency = currency
        self.categoryName = categoryName
        self.categoryColorHex = categoryColorHex
        self.categorySymbolName = categorySymbolName
        self.isTransfer = isTransfer
        self.isIgnored = isIgnored
        self.isPending = isPending
    }
}

/// Whether a series brings money in or takes it out.
public enum RecurringDirection: String, Sendable, CaseIterable, Codable {
    case outgoing
    case incoming

    public var displayName: String {
        switch self {
        case .outgoing: "Outgoing"
        case .incoming: "Incoming"
        }
    }
}

/// How often a recurring charge is expected. The detector only assigns a
/// cadence when the observed gaps fit one of these windows; anything in
/// between is treated as irregular so ordinary shopping is not mislabeled.
public enum RecurringCadence: String, Sendable, CaseIterable, Codable {
    case weekly
    case biweekly
    case monthly
    case quarterly
    case semiannual
    case yearly

    /// The observed median gap, in days, that maps to this cadence.
    var intervalRange: ClosedRange<Double> {
        switch self {
        case .weekly: 5...10
        case .biweekly: 11...18
        case .monthly: 26...35
        case .quarterly: 80...100
        case .semiannual: 165...200
        case .yearly: 340...390
        }
    }

    public var approximateDays: Double {
        switch self {
        case .weekly: 7
        case .biweekly: 14
        case .monthly: 30.44
        case .quarterly: 91.31
        case .semiannual: 182.62
        case .yearly: 365.25
        }
    }

    public var displayName: String {
        switch self {
        case .weekly: "Weekly"
        case .biweekly: "Every 2 weeks"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .semiannual: "Every 6 months"
        case .yearly: "Yearly"
        }
    }
}

/// One detected run of similar charges on a regular schedule.
public struct RecurringSeries: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let merchantKey: String
    public let direction: RecurringDirection
    public let cadence: RecurringCadence
    /// The median charge, signed (negative when money leaves the account).
    public let averageAmountMinorUnits: Int64
    public let latestAmountMinorUnits: Int64
    public let firstDate: Date
    public let lastDate: Date
    public let nextExpectedDate: Date
    /// The median gap between charges, in days.
    public let intervalDays: Double
    public let occurrences: Int
    /// 0...1; combines how many charges there are, how regular they are, and
    /// how stable the amount is.
    public let confidence: Double
    /// True when the amount moves enough to read as a bill rather than a fixed
    /// subscription.
    public let isVariableAmount: Bool
    public let categoryName: String?
    public let categoryColorHex: String?
    public let categorySymbolName: String?
    public let accountNames: [String]
    public let transactionIDs: [String]
    public let currency: Currency

    /// The amount normalized to a monthly cost, for comparing cadences.
    public var monthlyEquivalentMinorUnits: Int64 {
        guard intervalDays > 0 else { return abs(averageAmountMinorUnits) }
        let perMonth = Double(abs(averageAmountMinorUnits)) * (365.25 / 12.0) / intervalDays
        return Int64(perMonth.rounded())
    }

    /// Months or years between charges read as subscriptions; a weekly or
    /// two-weekly cadence is more likely a routine payment.
    public var isSubscription: Bool {
        cadence != .weekly && cadence != .biweekly
    }

    /// Set when the evidence is thinner, so the UI can hedge.
    public var confidenceLabel: String? {
        confidence < 0.7 ? "Possible" : nil
    }

    public func daysUntilNext(from date: Date = .now, calendar: Calendar = .current) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: nextExpectedDate)
        ).day ?? 0
    }

    public func isOverdue(from date: Date = .now, calendar: Calendar = .current) -> Bool {
        daysUntilNext(from: date, calendar: calendar) < 0
    }
}

/// Finds subscriptions and other regular payments from transaction history.
///
/// Deliberately conservative: a series needs at least three charges, a stable
/// sign, a recognizable cadence, and either stable amounts or (for a bill) a
/// variation small enough to stay periodic. Money movement is ignored.
public enum RecurringDetector {
    /// Three charges establish two gaps, the minimum to see a rhythm.
    public static let minimumOccurrences = 3

    public static func detect(
        _ inputs: [RecurringInput],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [RecurringSeries] {
        let eligible = inputs.filter {
            !$0.isTransfer && !$0.isIgnored && !$0.isPending && $0.amountMinorUnits != 0
        }
        let groups = Dictionary(grouping: eligible, by: groupKey)
        let detected = groups.values.compactMap { series(for: $0, now: now, calendar: calendar) }
        return detected.sorted(by: isOrderedBefore)
    }

    private static func groupKey(for input: RecurringInput) -> String {
        let direction = input.amountMinorUnits < 0 ? RecurringDirection.outgoing : .incoming
        return "\(direction.rawValue)|\(input.merchantKey)|\(input.accountID)"
    }

    private static func series(
        for rows: [RecurringInput],
        now: Date,
        calendar: Calendar
    ) -> RecurringSeries? {
        guard rows.count >= minimumOccurrences else { return nil }
        let sorted = rows.sorted { $0.date < $1.date }
        guard let first = sorted.first, let latest = sorted.last else { return nil }
        let isOutgoing = first.amountMinorUnits < 0
        // A refund and a charge with the same merchant must not form one series.
        guard sorted.allSatisfy({ ($0.amountMinorUnits < 0) == isOutgoing }) else { return nil }

        let dates = sorted.map(\.date)
        var intervals: [Double] = []
        for index in 1..<dates.count {
            intervals.append(dates[index].timeIntervalSince(dates[index - 1]) / 86_400)
        }
        guard !intervals.isEmpty else { return nil }

        let medianInterval = median(intervals)
        guard let cadence = cadence(forIntervalDays: medianInterval) else { return nil }

        // Monthly bills can drift a few days; weekly charges are expected to
        // land on the same weekday.
        let tolerance = max(3.0, medianInterval * 0.2)
        let consistent = intervals.filter { abs($0 - medianInterval) <= tolerance }.count
        let regularity = Double(consistent) / Double(intervals.count)
        guard regularity >= 0.7 else { return nil }

        let magnitudes = sorted.map { Double(abs($0.amountMinorUnits)) }
        let medianAmount = median(magnitudes)
        guard medianAmount > 0 else { return nil }
        let maxDeviation = magnitudes.map { abs($0 - medianAmount) / medianAmount }.max() ?? 0
        guard maxDeviation <= 0.40 else { return nil }
        // A weekly or two-weekly pattern of varying amounts is usually ordinary
        // errands, not a commitment, so hold it to a tighter amount.
        if cadence == .weekly || cadence == .biweekly, maxDeviation > 0.05 { return nil }

        let isVariable = maxDeviation > 0.05
        let amountFactor = isVariable ? max(0.6, 1.0 - maxDeviation) : 1.0
        let occurrenceFactor: Double = switch sorted.count {
        case 3: 0.65
        case 4: 0.78
        case 5: 0.86
        case 6: 0.92
        default: 0.95
        }
        let confidence = min(1.0, occurrenceFactor * regularity * amountFactor)

        let direction: RecurringDirection = isOutgoing ? .outgoing : .incoming
        let signedAverage = isOutgoing
            ? -Int64(medianAmount.rounded())
            : Int64(medianAmount.rounded())
        let next = calendar.date(
            byAdding: .day,
            value: max(1, Int(medianInterval.rounded())),
            to: latest.date
        ) ?? latest.date

        let categorized = sorted.last { $0.categoryName != nil }
        return RecurringSeries(
            id: groupKey(for: latest),
            displayName: latest.displayName,
            merchantKey: latest.merchantKey,
            direction: direction,
            cadence: cadence,
            averageAmountMinorUnits: signedAverage,
            latestAmountMinorUnits: latest.amountMinorUnits,
            firstDate: first.date,
            lastDate: latest.date,
            nextExpectedDate: next,
            intervalDays: medianInterval,
            occurrences: sorted.count,
            confidence: confidence,
            isVariableAmount: isVariable,
            categoryName: categorized?.categoryName,
            categoryColorHex: categorized?.categoryColorHex,
            categorySymbolName: categorized?.categorySymbolName,
            accountNames: Array(Set(sorted.map(\.accountName))).sorted(),
            transactionIDs: sorted.map(\.id),
            currency: latest.currency
        )
    }

    private static func cadence(forIntervalDays days: Double) -> RecurringCadence? {
        RecurringCadence.allCases.first { $0.intervalRange.contains(days) }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func isOrderedBefore(_ lhs: RecurringSeries, _ rhs: RecurringSeries) -> Bool {
        if lhs.direction != rhs.direction { return lhs.direction == .outgoing }
        if lhs.monthlyEquivalentMinorUnits != rhs.monthlyEquivalentMinorUnits {
            return lhs.monthlyEquivalentMinorUnits > rhs.monthlyEquivalentMinorUnits
        }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}
