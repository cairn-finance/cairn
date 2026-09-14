import Foundation

/// A transaction reduced to the fields insights need, so the calculator stays
/// pure and unit-testable without SwiftData. Callers should pass transactions
/// for a single currency; totals are never summed across currencies.
public struct InsightTransaction: Sendable, Hashable {
    public let date: Date
    public let amountMinorUnits: Int64
    public let categoryName: String?
    public let categoryColorHex: String?
    public let merchant: String
    public let accountName: String
    public let isTransfer: Bool
    public let isIgnored: Bool
    public let isPending: Bool

    public init(
        date: Date,
        amountMinorUnits: Int64,
        categoryName: String? = nil,
        categoryColorHex: String? = nil,
        merchant: String = "",
        accountName: String = "",
        isTransfer: Bool = false,
        isIgnored: Bool = false,
        isPending: Bool = false
    ) {
        self.date = date
        self.amountMinorUnits = amountMinorUnits
        self.categoryName = categoryName
        self.categoryColorHex = categoryColorHex
        self.merchant = merchant
        self.accountName = accountName
        self.isTransfer = isTransfer
        self.isIgnored = isIgnored
        self.isPending = isPending
    }
}

/// Income, spending, and net for one calendar month. Spending is stored as a
/// positive magnitude so it reads naturally in charts.
public struct MonthlyTotals: Sendable, Hashable, Identifiable {
    public let monthStart: Date
    public let incomeMinorUnits: Int64
    public let spendingMinorUnits: Int64

    public var id: Date { monthStart }
    public var netMinorUnits: Int64 { incomeMinorUnits - spendingMinorUnits }

    public init(monthStart: Date, incomeMinorUnits: Int64, spendingMinorUnits: Int64) {
        self.monthStart = monthStart
        self.incomeMinorUnits = incomeMinorUnits
        self.spendingMinorUnits = spendingMinorUnits
    }
}

/// Spending in one category for the selected month, with the previous month's
/// figure so the UI can show a month-over-month change.
public struct CategoryBreakdown: Sendable, Hashable, Identifiable {
    public let name: String
    public let colorHex: String
    public let amountMinorUnits: Int64
    public let previousAmountMinorUnits: Int64

    public var id: String { name }

    /// Relative change versus the previous month, or nil when there is no
    /// previous spending to compare against.
    public var changeRatio: Double? {
        guard previousAmountMinorUnits > 0 else { return nil }
        return Double(amountMinorUnits - previousAmountMinorUnits) / Double(previousAmountMinorUnits)
    }

    public init(name: String, colorHex: String, amountMinorUnits: Int64, previousAmountMinorUnits: Int64) {
        self.name = name
        self.colorHex = colorHex
        self.amountMinorUnits = amountMinorUnits
        self.previousAmountMinorUnits = previousAmountMinorUnits
    }
}

public struct MerchantTotal: Sendable, Hashable, Identifiable {
    public let name: String
    public let amountMinorUnits: Int64
    public var id: String { name }

    public init(name: String, amountMinorUnits: Int64) {
        self.name = name
        self.amountMinorUnits = amountMinorUnits
    }
}

/// A cumulative spending point for one day of a month, used by the pace chart.
public struct PacePoint: Sendable, Hashable, Identifiable {
    public let day: Int
    public let amountMinorUnits: Int64

    public var id: Int { day }

    public init(day: Int, amountMinorUnits: Int64) {
        self.day = day
        self.amountMinorUnits = amountMinorUnits
    }
}

/// Everything the insights screen needs for one month, precomputed.
public struct InsightsSnapshot: Sendable {
    public let monthStart: Date
    public let current: MonthlyTotals
    public let previous: MonthlyTotals

    /// Categories with spending this month, largest first. Categories that only
    /// had spending last month are still included so a drop to zero is visible.
    public let categories: [CategoryBreakdown]

    /// Ascending monthly totals ending at `monthStart`, for the trend chart.
    public let months: [MonthlyTotals]

    /// Largest merchants this month, by spend.
    public let topMerchants: [MerchantTotal]

    public let transactionCount: Int

    /// Cumulative spending by day-of-month for the selected month.
    public let cumulative: [PacePoint]
    /// Total days in the selected month.
    public let daysInMonth: Int
    /// Last day with data (today's day for the current month, else all days).
    public let lastDayWithData: Int
    /// Average daily spend over the months before the selected one.
    public let averageDailyPace: Int64
    /// Spending last month through the same point in the month.
    public let previousToDateSpending: Int64
    /// Categories with the largest dollar change versus last month.
    public let topMoverNames: Set<String>

    public init(
        monthStart: Date,
        current: MonthlyTotals,
        previous: MonthlyTotals,
        categories: [CategoryBreakdown],
        months: [MonthlyTotals],
        topMerchants: [MerchantTotal],
        transactionCount: Int,
        cumulative: [PacePoint],
        daysInMonth: Int,
        lastDayWithData: Int,
        averageDailyPace: Int64,
        previousToDateSpending: Int64,
        topMoverNames: Set<String>
    ) {
        self.monthStart = monthStart
        self.current = current
        self.previous = previous
        self.categories = categories
        self.months = months
        self.topMerchants = topMerchants
        self.transactionCount = transactionCount
        self.cumulative = cumulative
        self.daysInMonth = daysInMonth
        self.lastDayWithData = lastDayWithData
        self.averageDailyPace = averageDailyPace
        self.previousToDateSpending = previousToDateSpending
        self.topMoverNames = topMoverNames
    }

    public var spendingChangeRatio: Double? {
        guard previous.spendingMinorUnits > 0 else { return nil }
        return Double(current.spendingMinorUnits - previous.spendingMinorUnits)
            / Double(previous.spendingMinorUnits)
    }

    /// Spending so far this month (or the whole month for a past one).
    public var currentToDateSpending: Int64 {
        cumulative.last?.amountMinorUnits ?? current.spendingMinorUnits
    }

    /// Change versus the same point in the previous month. Comparing like for
    /// like avoids the misleading jump you get from a full-month baseline early
    /// in the month.
    public var spendingChangeVsDate: Double? {
        guard previousToDateSpending > 0 else { return nil }
        return Double(currentToDateSpending - previousToDateSpending) / Double(previousToDateSpending)
    }

    /// Projected spend for the whole month at the trailing average pace.
    public var projectedSpending: Int64 {
        averageDailyPace > 0 ? averageDailyPace * Int64(daysInMonth) : current.spendingMinorUnits
    }

    public var netChangeRatio: Double? {
        guard previous.netMinorUnits != 0 else { return nil }
        return Double(current.netMinorUnits - previous.netMinorUnits)
            / Double(abs(previous.netMinorUnits))
    }

    /// Average daily spend, based on elapsed days for the current month and on
    /// calendar days for a past month.
    public func averageDailySpending(now: Date = .now, calendar: Calendar = .current) -> Int64 {
        let days: Int
        if calendar.isDate(monthStart, equalTo: now, toGranularity: .month) {
            days = max(1, calendar.component(.day, from: now))
        } else {
            days = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        }
        return current.spendingMinorUnits / Int64(days)
    }
}

/// Builds month-over-month spending and income summaries from transactions.
///
/// Deliberately conservative: transfers and ignored rows are excluded from
/// income and spending (they would double count or aren't real cash flow), and
/// pending rows are excluded so a charge isn't counted twice once it posts.
public enum InsightsCalculator {
    public static let uncategorizedName = "Uncategorized"
    public static let uncategorizedColorHex = "#8E8E93"

    public static func snapshot(
        transactions: [InsightTransaction],
        month: Date,
        historyMonths: Int = 6,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> InsightsSnapshot {
        let monthStart = startOfMonth(month, calendar: calendar)
        let relevant = transactions.filter { $0.includedInInsights }

        let current = totals(for: monthStart, transactions: relevant, calendar: calendar)
        let previousStart = calendar.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
        let previous = totals(for: previousStart, transactions: relevant, calendar: calendar)

        let months = monthlyTotals(
            endingAt: monthStart,
            count: max(1, historyMonths),
            transactions: relevant,
            calendar: calendar
        )
        let categories = categoryBreakdown(
            monthStart: monthStart,
            previousStart: previousStart,
            transactions: relevant,
            calendar: calendar
        )
        let merchants = topMerchants(monthStart: monthStart, transactions: relevant, calendar: calendar)
        let count = relevant.filter { isInMonth($0.date, monthStart: monthStart, calendar: calendar) }.count

        let cumulative = cumulativeSpending(
            transactions: relevant,
            month: monthStart,
            now: now,
            calendar: calendar
        )
        let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let isCurrentMonth = calendar.isDate(monthStart, equalTo: now, toGranularity: .month)
        let lastDayWithData = isCurrentMonth
            ? min(max(1, calendar.component(.day, from: now)), daysInMonth)
            : daysInMonth
        let averageDailyPace = averageDailySpend(
            transactions: relevant,
            before: monthStart,
            months: 3,
            calendar: calendar
        )
        let previousCumulative = cumulativeSpending(
            transactions: relevant,
            month: previousStart,
            now: now,
            calendar: calendar
        )
        let previousDays = calendar.range(of: .day, in: .month, for: previousStart)?.count ?? 30
        let compareDay = min(lastDayWithData, previousDays)
        let previousToDate = previousCumulative.last(where: { $0.day <= compareDay })?.amountMinorUnits ?? 0

        let topMovers = Set(
            categories
                .map { ($0.name, abs($0.amountMinorUnits - $0.previousAmountMinorUnits)) }
                .sorted { $0.1 > $1.1 }
                .prefix(3)
                .filter { $0.1 > 0 }
                .map(\.0)
        )

        return InsightsSnapshot(
            monthStart: monthStart,
            current: current,
            previous: previous,
            categories: categories,
            months: months,
            topMerchants: merchants,
            transactionCount: count,
            cumulative: cumulative,
            daysInMonth: daysInMonth,
            lastDayWithData: lastDayWithData,
            averageDailyPace: averageDailyPace,
            previousToDateSpending: previousToDate,
            topMoverNames: topMovers
        )
    }

    /// Cumulative spending within `month`, one point per day through the last
    /// day with data. Used to draw the pace line against an average reference.
    public static func cumulativeSpending(
        transactions: [InsightTransaction],
        month: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [PacePoint] {
        let monthStart = startOfMonth(month, calendar: calendar)
        let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let isCurrent = calendar.isDate(monthStart, equalTo: now, toGranularity: .month)
        let lastDay = isCurrent ? min(max(1, calendar.component(.day, from: now)), daysInMonth) : daysInMonth

        var daily = [Int64](repeating: 0, count: lastDay + 1)
        for transaction in transactions
            where transaction.includedInInsights
            && transaction.amountMinorUnits < 0
            && isInMonth(transaction.date, monthStart: monthStart, calendar: calendar) {
            let day = calendar.component(.day, from: transaction.date)
            guard day >= 1, day <= lastDay else { continue }
            daily[day] += abs(transaction.amountMinorUnits)
        }

        var running: Int64 = 0
        var points: [PacePoint] = []
        for day in 1...lastDay {
            running += daily[day]
            points.append(PacePoint(day: day, amountMinorUnits: running))
        }
        return points
    }

    /// Average daily spend over the `months` months before `month`, used as the
    /// straight reference line in the pace chart.
    public static func averageDailySpend(
        transactions: [InsightTransaction],
        before month: Date,
        months: Int = 3,
        calendar: Calendar = .current
    ) -> Int64 {
        guard months > 0 else { return 0 }
        let monthStart = startOfMonth(month, calendar: calendar)
        let relevant = transactions.filter { $0.includedInInsights }
        var total: Int64 = 0
        var days = 0
        for offset in 1...months {
            guard let start = calendar.date(byAdding: .month, value: -offset, to: monthStart),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { continue }
            // Skip months with no data at all, so a new install isn't diluted by
            // months that predate its history.
            let hasCoverage = relevant.contains { $0.date >= start && $0.date < end }
            guard hasCoverage else { continue }
            total += totals(for: start, transactions: relevant, calendar: calendar).spendingMinorUnits
            days += calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        }
        return days > 0 ? total / Int64(days) : 0
    }

    /// Totals for a specific month.
    public static func totals(
        for month: Date,
        transactions: [InsightTransaction],
        calendar: Calendar = .current
    ) -> MonthlyTotals {
        let monthStart = startOfMonth(month, calendar: calendar)
        var income: Int64 = 0
        var spending: Int64 = 0
        for transaction in transactions
            where transaction.includedInInsights
            && isInMonth(transaction.date, monthStart: monthStart, calendar: calendar) {
            if transaction.amountMinorUnits >= 0 {
                income += transaction.amountMinorUnits
            } else {
                spending += abs(transaction.amountMinorUnits)
            }
        }
        return MonthlyTotals(monthStart: monthStart, incomeMinorUnits: income, spendingMinorUnits: spending)
    }

    /// Ascending totals for the `count` months ending at `month`.
    public static func monthlyTotals(
        endingAt month: Date,
        count: Int,
        transactions: [InsightTransaction],
        calendar: Calendar = .current
    ) -> [MonthlyTotals] {
        let end = startOfMonth(month, calendar: calendar)
        var result: [MonthlyTotals] = []
        for offset in stride(from: max(1, count) - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .month, value: -offset, to: end) else { continue }
            result.append(totals(for: start, transactions: transactions, calendar: calendar))
        }
        return result
    }

    static func categoryBreakdown(
        monthStart: Date,
        previousStart: Date,
        transactions: [InsightTransaction],
        calendar: Calendar
    ) -> [CategoryBreakdown] {
        var currentSpend: [String: Int64] = [:]
        var currentColor: [String: String] = [:]
        var previousSpend: [String: Int64] = [:]

        for transaction in transactions
            where transaction.includedInInsights && transaction.amountMinorUnits < 0 {
            let name: String
            if let categoryName = transaction.categoryName, !categoryName.isEmpty {
                name = categoryName
            } else {
                name = uncategorizedName
            }
            if isInMonth(transaction.date, monthStart: monthStart, calendar: calendar) {
                currentSpend[name, default: 0] += abs(transaction.amountMinorUnits)
                if let hex = transaction.categoryColorHex, !hex.isEmpty {
                    currentColor[name] = hex
                }
            } else if isInMonth(transaction.date, monthStart: previousStart, calendar: calendar) {
                previousSpend[name, default: 0] += abs(transaction.amountMinorUnits)
            }
        }

        let names = Set(currentSpend.keys).union(previousSpend.keys)
        return names
            .map { name in
                CategoryBreakdown(
                    name: name,
                    colorHex: currentColor[name] ?? uncategorizedColorHex,
                    amountMinorUnits: currentSpend[name] ?? 0,
                    previousAmountMinorUnits: previousSpend[name] ?? 0
                )
            }
            .sorted {
                if $0.amountMinorUnits != $1.amountMinorUnits {
                    return $0.amountMinorUnits > $1.amountMinorUnits
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    static func topMerchants(
        monthStart: Date,
        transactions: [InsightTransaction],
        calendar: Calendar,
        limit: Int = 8
    ) -> [MerchantTotal] {
        var totals: [String: Int64] = [:]
        for transaction in transactions
            where transaction.includedInInsights
            && transaction.amountMinorUnits < 0
            && isInMonth(transaction.date, monthStart: monthStart, calendar: calendar) {
            let name = transaction.merchant.isEmpty ? "Unknown" : transaction.merchant
            totals[name, default: 0] += abs(transaction.amountMinorUnits)
        }
        return totals
            .map { MerchantTotal(name: $0.key, amountMinorUnits: $0.value) }
            .sorted {
                if $0.amountMinorUnits != $1.amountMinorUnits {
                    return $0.amountMinorUnits > $1.amountMinorUnits
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func startOfMonth(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    private static func isInMonth(_ date: Date, monthStart: Date, calendar: Calendar) -> Bool {
        guard let interval = calendar.dateInterval(of: .month, for: monthStart) else { return false }
        return interval.contains(date)
    }
}

extension InsightTransaction {
    /// Transfers, ignored rows, and pending rows are left out of income and
    /// spending summaries.
    var includedInInsights: Bool {
        !isTransfer && !isIgnored && !isPending
    }
}
