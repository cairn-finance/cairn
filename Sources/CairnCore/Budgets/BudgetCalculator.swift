import Foundation

/// A transaction reduced to the values needed to calculate category budgets.
public struct BudgetTransaction: Sendable, Hashable {
    public let date: Date
    public let amountMinorUnits: Int64
    public let categoryUUID: UUID?
    public let categoryName: String?
    public let isTransfer: Bool
    public let isIgnored: Bool
    public let isPending: Bool
    public let smoothingAllocation: BudgetSmoothingAllocation?

    public init(
        date: Date,
        amountMinorUnits: Int64,
        categoryUUID: UUID?,
        categoryName: String?,
        isTransfer: Bool,
        isIgnored: Bool,
        isPending: Bool,
        smoothingAllocation: BudgetSmoothingAllocation? = nil
    ) {
        self.date = date
        self.amountMinorUnits = amountMinorUnits
        self.categoryUUID = categoryUUID
        self.categoryName = categoryName
        self.isTransfer = isTransfer
        self.isIgnored = isIgnored
        self.isPending = isPending
        self.smoothingAllocation = smoothingAllocation
    }
}

/// A category value safe to pass from SwiftData into the budget calculator.
public struct BudgetCategory: Sendable, Hashable {
    public let uuid: UUID
    public let name: String
    public let colorHex: String
    public let symbolName: String
    public let sortOrder: Int
    public let isArchived: Bool

    public init(
        uuid: UUID,
        name: String,
        colorHex: String,
        symbolName: String,
        sortOrder: Int,
        isArchived: Bool
    ) {
        self.uuid = uuid
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.sortOrder = sortOrder
        self.isArchived = isArchived
    }
}

/// A recurring category limit or a one-month override, copied from SwiftData.
public struct BudgetSetting: Sendable, Hashable {
    public let uuid: UUID
    public let categoryUUID: UUID
    public let currency: Currency
    public let monthKey: String
    public let amountMinorUnits: Int64
    public let isMonthOverride: Bool
    public let isEnabled: Bool
    public let timeZoneIdentifier: String
    public let modifiedAt: Date

    public init(
        uuid: UUID,
        categoryUUID: UUID,
        currency: Currency,
        monthKey: String,
        amountMinorUnits: Int64,
        isMonthOverride: Bool,
        isEnabled: Bool,
        timeZoneIdentifier: String,
        modifiedAt: Date
    ) {
        self.uuid = uuid
        self.categoryUUID = categoryUUID
        self.currency = currency
        self.monthKey = monthKey
        self.amountMinorUnits = amountMinorUnits
        self.isMonthOverride = isMonthOverride
        self.isEnabled = isEnabled
        self.timeZoneIdentifier = timeZoneIdentifier
        self.modifiedAt = modifiedAt
    }
}

public struct BudgetLine: Sendable, Hashable, Identifiable {
    public let category: BudgetCategory
    public let plannedMinorUnits: Int64?
    public let spentMinorUnits: Int64
    public let effectiveSetting: BudgetSetting?

    public var id: UUID { category.uuid }

    public var remainingMinorUnits: Int64? {
        guard let plannedMinorUnits else { return nil }
        return MinorUnits.subtractClamped(plannedMinorUnits, spentMinorUnits)
    }

    public init(
        category: BudgetCategory,
        plannedMinorUnits: Int64?,
        spentMinorUnits: Int64,
        effectiveSetting: BudgetSetting? = nil
    ) {
        self.category = category
        self.plannedMinorUnits = plannedMinorUnits
        self.spentMinorUnits = spentMinorUnits
        self.effectiveSetting = effectiveSetting
    }
}

/// Net spending for one completed month used to explain a recommendation.
public struct BudgetMonthSpending: Sendable, Hashable, Identifiable {
    public let monthKey: String
    public let amountMinorUnits: Int64

    public var id: String { monthKey }

    public init(monthKey: String, amountMinorUnits: Int64) {
        self.monthKey = monthKey
        self.amountMinorUnits = amountMinorUnits
    }
}

/// A starting monthly limit estimated from completed spending history.
public struct BudgetRecommendation: Sendable, Hashable, Identifiable {
    public let category: BudgetCategory
    public let monthsWithSpending: Int
    public let monthsSampled: Int
    public let typicalActiveMonthMinorUnits: Int64
    public let suggestedLimitMinorUnits: Int64
    public let monthlySpending: [BudgetMonthSpending]

    public var id: UUID { category.uuid }

    public init(
        category: BudgetCategory,
        monthsWithSpending: Int,
        monthsSampled: Int,
        typicalActiveMonthMinorUnits: Int64,
        suggestedLimitMinorUnits: Int64,
        monthlySpending: [BudgetMonthSpending] = []
    ) {
        self.category = category
        self.monthsWithSpending = monthsWithSpending
        self.monthsSampled = monthsSampled
        self.typicalActiveMonthMinorUnits = typicalActiveMonthMinorUnits
        self.suggestedLimitMinorUnits = suggestedLimitMinorUnits
        self.monthlySpending = monthlySpending
    }
}

public struct BudgetSnapshot: Sendable {
    public let monthStart: Date
    public let monthKey: String
    public let currency: Currency
    public let lines: [BudgetLine]
    public let plannedMinorUnits: Int64
    public let budgetedSpentMinorUnits: Int64
    public let spentMinorUnits: Int64
    public let unbudgetedMinorUnits: Int64

    public init(
        monthStart: Date,
        monthKey: String,
        currency: Currency,
        lines: [BudgetLine],
        plannedMinorUnits: Int64,
        budgetedSpentMinorUnits: Int64,
        spentMinorUnits: Int64,
        unbudgetedMinorUnits: Int64
    ) {
        self.monthStart = monthStart
        self.monthKey = monthKey
        self.currency = currency
        self.lines = lines
        self.plannedMinorUnits = plannedMinorUnits
        self.budgetedSpentMinorUnits = budgetedSpentMinorUnits
        self.spentMinorUnits = spentMinorUnits
        self.unbudgetedMinorUnits = unbudgetedMinorUnits
    }

    public var remainingMinorUnits: Int64 {
        MinorUnits.subtractClamped(plannedMinorUnits, budgetedSpentMinorUnits)
    }
}

/// Computes planned, spent, and remaining amounts for one currency and month.
public enum BudgetCalculator {
    private static let excludedCategoryNames: Set<String> = [
        "Income", "Transfers", "Credit Card Payments", "Loan Payments", "Uncategorized",
    ]

    static func isExcludedCategory(_ name: String?) -> Bool {
        guard let name else { return false }
        return excludedCategoryNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func isUncategorized(_ name: String?) -> Bool {
        name?.caseInsensitiveCompare("Uncategorized") == .orderedSame
    }

    public static func monthKey(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 1970, components.month ?? 1)
    }

    public static func startOfMonth(_ key: String, timeZone: TimeZone = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    public static func shiftMonth(_ key: String, by amount: Int, timeZone: TimeZone = .current) -> String? {
        guard let start = startOfMonth(key, timeZone: timeZone) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let next = calendar.date(byAdding: .month, value: amount, to: start) else { return nil }
        return monthKey(for: next, timeZone: timeZone)
    }

    /// Returns chronological month keys for the completed months before `currentMonthKey`.
    public static func completedMonthKeys(
        before currentMonthKey: String,
        count: Int,
        timeZone: TimeZone = .current
    ) -> [String] {
        guard count > 0 else { return [] }
        return (1...count).reversed().compactMap {
            shiftMonth(currentMonthKey, by: -$0, timeZone: timeZone)
        }
    }

    /// Suggests a starting limit from the median of months with net spending.
    /// Categories need activity in at least `minimumActiveMonths` completed
    /// months; income, transfers, ignored rows, and pending rows are excluded.
    public static func recommendations(
        transactions: [BudgetTransaction],
        categories: [BudgetCategory],
        currency: Currency,
        monthKeys: [String],
        minimumActiveMonths: Int = 2,
        timeZone: TimeZone = .current
    ) -> [BudgetRecommendation] {
        guard !monthKeys.isEmpty,
              minimumActiveMonths > 0,
              (0...6).contains(currency.exponent) else { return [] }

        let sampledMonths = Set(monthKeys)
        var monthlySpending: [String: [UUID: Int64]] = [:]
        for transaction in transactions {
            let month = monthKey(for: transaction.date, timeZone: timeZone)
            guard sampledMonths.contains(month),
                  !transaction.isTransfer,
                  !transaction.isIgnored,
                  !transaction.isPending,
                  !isExcludedCategory(transaction.categoryName),
                  let categoryUUID = transaction.categoryUUID,
                  transaction.amountMinorUnits != 0 else { continue }

            var totals = monthlySpending[month, default: [:]]
            if transaction.amountMinorUnits < 0 {
                totals[categoryUUID] = MinorUnits.addClamped(
                    totals[categoryUUID] ?? 0,
                    MinorUnits.absClamped(transaction.amountMinorUnits)
                )
            } else {
                totals[categoryUUID] = MinorUnits.subtractClamped(
                    totals[categoryUUID] ?? 0,
                    transaction.amountMinorUnits
                )
            }
            monthlySpending[month] = totals
        }

        let scale = (0..<currency.exponent).reduce(Int64(1)) { value, _ in
            MinorUnits.multiplyClamped(value, 10)
        }
        let roundingStep = MinorUnits.multiplyClamped(scale, 5)

        return categories
            .filter { !$0.isArchived && !isExcludedCategory($0.name) }
            .compactMap { category -> BudgetRecommendation? in
                let monthDetails = monthKeys.map { month in
                    BudgetMonthSpending(
                        monthKey: month,
                        amountMinorUnits: max(0, monthlySpending[month]?[category.uuid] ?? 0)
                    )
                }
                let activeMonths = monthDetails
                    .map(\.amountMinorUnits)
                    .filter { $0 > 0 }
                    .sorted()
                guard activeMonths.count >= minimumActiveMonths,
                      let typical = median(of: activeMonths) else { return nil }

                return BudgetRecommendation(
                    category: category,
                    monthsWithSpending: activeMonths.count,
                    monthsSampled: monthKeys.count,
                    typicalActiveMonthMinorUnits: typical,
                    suggestedLimitMinorUnits: roundUp(typical, to: roundingStep),
                    monthlySpending: monthDetails
                )
            }
            .sorted {
                if $0.category.sortOrder != $1.category.sortOrder {
                    return $0.category.sortOrder < $1.category.sortOrder
                }
                return $0.category.name.localizedStandardCompare($1.category.name) == .orderedAscending
            }
    }

    /// The setting that determines each category's limit in a given month.
    /// Disabled settings remain in the result so editors can explain removals.
    public static func effectiveSettings(
        _ settings: [BudgetSetting],
        monthKey: String,
        currency: Currency
    ) -> [UUID: BudgetSetting] {
        let relevant = settings.filter { $0.currency == currency }
        let rules = latestSettings(relevant.filter { !$0.isMonthOverride && $0.monthKey <= monthKey })
        let overrides = latestSettings(relevant.filter { $0.isMonthOverride && $0.monthKey == monthKey })
        var effective: [UUID: BudgetSetting] = [:]
        for rule in rules { effective[rule.categoryUUID] = rule }
        for override in overrides { effective[override.categoryUUID] = override }
        return effective
    }

    public static func snapshot(
        transactions: [BudgetTransaction],
        categories: [BudgetCategory],
        settings: [BudgetSetting],
        monthKey: String,
        currency: Currency,
        timeZone: TimeZone = .current
    ) -> BudgetSnapshot {
        let monthStart = startOfMonth(monthKey, timeZone: timeZone) ?? .now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart

        let effectiveSettings = effectiveSettings(settings, monthKey: monthKey, currency: currency)
        let planned = effectiveSettings.compactMapValues { $0.isEnabled ? $0.amountMinorUnits : nil }

        var spending: [UUID: Int64] = [:]
        var uncategorized: Int64 = 0
        for transaction in transactions where
            transaction.date >= monthStart
            && transaction.date < nextMonth
            && !transaction.isTransfer
            && !transaction.isIgnored
            && !transaction.isPending
            && !isExcludedCategory(transaction.categoryName) {
            guard transaction.amountMinorUnits != 0 else { continue }
            if transaction.amountMinorUnits < 0 {
                let expense = MinorUnits.absClamped(transaction.amountMinorUnits)
                if let categoryUUID = transaction.categoryUUID, !isUncategorized(transaction.categoryName) {
                    spending[categoryUUID] = MinorUnits.addClamped(spending[categoryUUID] ?? 0, expense)
                } else {
                    uncategorized = MinorUnits.addClamped(uncategorized, expense)
                }
            } else if transaction.categoryUUID != nil, isUncategorized(transaction.categoryName) {
                uncategorized = MinorUnits.subtractClamped(uncategorized, transaction.amountMinorUnits)
            } else if let categoryUUID = transaction.categoryUUID,
                      transaction.categoryName?.caseInsensitiveCompare("Income") != .orderedSame {
                spending[categoryUUID] = MinorUnits.subtractClamped(
                    spending[categoryUUID] ?? 0,
                    transaction.amountMinorUnits
                )
            }
        }

        // A reimbursement can arrive after, or exceed, the expense it offsets.
        // Keep a category's reported spending non-negative rather than letting
        // a correction create negative budget usage.
        spending = spending.mapValues { max(0, $0) }
        uncategorized = max(0, uncategorized)

        let categoriesByID = Dictionary(categories.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let categoryIDs = Set(planned.keys)
            .union(spending.keys)
            .union(categories.filter {
                !$0.isArchived && !isExcludedCategory($0.name)
            }.map(\.uuid))
        let lines = categoryIDs.compactMap { id -> BudgetLine? in
            guard let category = categoriesByID[id] else { return nil }
            return BudgetLine(
                category: category,
                plannedMinorUnits: planned[id],
                spentMinorUnits: spending[id] ?? 0,
                effectiveSetting: effectiveSettings[id]
            )
        }.sorted {
            if $0.category.sortOrder != $1.category.sortOrder {
                return $0.category.sortOrder < $1.category.sortOrder
            }
            return $0.category.name.localizedStandardCompare($1.category.name) == .orderedAscending
        }

        let plannedTotal = planned.values.reduce(Int64(0), MinorUnits.addClamped)
        let categorizedSpent = spending.values.reduce(Int64(0), MinorUnits.addClamped)
        let budgetedSpent = planned.keys.reduce(Int64(0)) {
            MinorUnits.addClamped($0, spending[$1] ?? 0)
        }
        let allSpent = MinorUnits.addClamped(categorizedSpent, uncategorized)
        let unbudgeted = lines
            .filter { $0.plannedMinorUnits == nil }
            .reduce(uncategorized) { MinorUnits.addClamped($0, $1.spentMinorUnits) }

        return BudgetSnapshot(
            monthStart: monthStart,
            monthKey: monthKey,
            currency: currency,
            lines: lines,
            plannedMinorUnits: plannedTotal,
            budgetedSpentMinorUnits: budgetedSpent,
            spentMinorUnits: allSpent,
            unbudgetedMinorUnits: unbudgeted
        )
    }

    private static func latestSettings(_ values: [BudgetSetting]) -> [BudgetSetting] {
        Dictionary(grouping: values, by: \.categoryUUID).compactMap { _, group in
            group.sorted {
                if $0.monthKey != $1.monthKey { return $0.monthKey > $1.monthKey }
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.uuid.uuidString < $1.uuid.uuidString
            }.first
        }
    }

    private static func median(of sortedValues: [Int64]) -> Int64? {
        guard !sortedValues.isEmpty else { return nil }
        let middle = sortedValues.count / 2
        guard sortedValues.count.isMultiple(of: 2) else { return sortedValues[middle] }
        let lower = sortedValues[middle - 1]
        let upper = sortedValues[middle]
        return lower / 2 + upper / 2 + (lower % 2 + upper % 2) / 2
    }

    private static func roundUp(_ value: Int64, to step: Int64) -> Int64 {
        guard step > 0 else { return value }
        let units = value / step + (value % step == 0 ? 0 : 1)
        return MinorUnits.multiplyClamped(units, step)
    }
}
