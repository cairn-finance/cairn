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

    public init(
        monthStart: Date,
        current: MonthlyTotals,
        previous: MonthlyTotals,
        categories: [CategoryBreakdown],
        months: [MonthlyTotals],
        topMerchants: [MerchantTotal],
        transactionCount: Int
    ) {
        self.monthStart = monthStart
        self.current = current
        self.previous = previous
        self.categories = categories
        self.months = months
        self.topMerchants = topMerchants
        self.transactionCount = transactionCount
    }

    public var spendingChangeRatio: Double? {
        guard previous.spendingMinorUnits > 0 else { return nil }
        return Double(current.spendingMinorUnits - previous.spendingMinorUnits)
            / Double(previous.spendingMinorUnits)
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

        return InsightsSnapshot(
            monthStart: monthStart,
            current: current,
            previous: previous,
            categories: categories,
            months: months,
            topMerchants: merchants,
            transactionCount: count
        )
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
        for transaction in transactions where isInMonth(transaction.date, monthStart: monthStart, calendar: calendar) {
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

        for transaction in transactions where transaction.amountMinorUnits < 0 {
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
            where transaction.amountMinorUnits < 0
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
