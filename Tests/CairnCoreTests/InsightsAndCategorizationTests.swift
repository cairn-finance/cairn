import Foundation
import Testing
@testable import CairnCore

@Suite("Insights calculator")
struct InsightsCalculatorTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    private func transactions() -> [InsightTransaction] {
        [
            // January
            InsightTransaction(
                date: date(2026, 1, 4), amountMinorUnits: -5_000,
                categoryName: "Groceries", merchant: "Whole Foods"
            ),
            InsightTransaction(
                date: date(2026, 1, 6), amountMinorUnits: -4_000,
                categoryName: "Dining", merchant: "Blue Bottle"
            ),
            InsightTransaction(date: date(2026, 1, 8), amountMinorUnits: 500_000, categoryName: "Income"),
            // February
            InsightTransaction(
                date: date(2026, 2, 3), amountMinorUnits: -8_000,
                categoryName: "Groceries", categoryColorHex: "#34C759", merchant: "Whole Foods"
            ),
            InsightTransaction(
                date: date(2026, 2, 5), amountMinorUnits: -2_000,
                categoryName: "Dining", merchant: "Blue Bottle"
            ),
            InsightTransaction(date: date(2026, 2, 10), amountMinorUnits: 500_000, categoryName: "Income"),
            InsightTransaction(
                date: date(2026, 2, 12), amountMinorUnits: -3_000,
                categoryName: "Groceries", merchant: "Whole Foods"
            ),
            // Excluded from income/spending.
            InsightTransaction(
                date: date(2026, 2, 15), amountMinorUnits: -10_000,
                categoryName: "Transfers", merchant: "Transfer", isTransfer: true
            ),
            InsightTransaction(
                date: date(2026, 2, 16), amountMinorUnits: -7_000,
                categoryName: "Dining", merchant: "Hidden", isIgnored: true
            ),
            InsightTransaction(
                date: date(2026, 2, 17), amountMinorUnits: -5_000,
                categoryName: "Dining", merchant: "Pending", isPending: true
            ),
        ]
    }

    @Test("Computes income, spending, and net for the month")
    func monthlyTotals() {
        let snapshot = InsightsCalculator.snapshot(
            transactions: transactions(),
            month: date(2026, 2, 1),
            historyMonths: 3,
            now: date(2026, 3, 15),
            calendar: Self.calendar
        )
        #expect(snapshot.current.incomeMinorUnits == 500_000)
        #expect(snapshot.current.spendingMinorUnits == 13_000)
        #expect(snapshot.current.netMinorUnits == 487_000)
        #expect(snapshot.transactionCount == 4)
    }

    @Test("Compares against the previous month")
    func monthOverMonth() {
        let snapshot = InsightsCalculator.snapshot(
            transactions: transactions(),
            month: date(2026, 2, 1),
            historyMonths: 3,
            now: date(2026, 3, 15),
            calendar: Self.calendar
        )
        #expect(snapshot.previous.spendingMinorUnits == 9_000)
        let change = try? #require(snapshot.spendingChangeRatio)
        #expect(abs((change ?? 0) - (4_000.0 / 9_000.0)) < 0.0001)
    }

    @Test("Breaks spending out by category with the previous month")
    func categories() {
        let snapshot = InsightsCalculator.snapshot(
            transactions: transactions(),
            month: date(2026, 2, 1),
            historyMonths: 3,
            now: date(2026, 3, 15),
            calendar: Self.calendar
        )
        #expect(snapshot.categories.count == 2)
        #expect(snapshot.categories.first?.name == "Groceries")
        #expect(snapshot.categories.first?.amountMinorUnits == 11_000)
        #expect(snapshot.categories.first?.previousAmountMinorUnits == 5_000)
        #expect(snapshot.categories.first?.colorHex == "#34C759")
        #expect(snapshot.categories.last?.name == "Dining")
    }

    @Test("Builds an ascending monthly trend")
    func monthlyTrend() {
        let snapshot = InsightsCalculator.snapshot(
            transactions: transactions(),
            month: date(2026, 2, 1),
            historyMonths: 3,
            now: date(2026, 3, 15),
            calendar: Self.calendar
        )
        #expect(snapshot.months.count == 3)
        #expect(snapshot.months.last?.spendingMinorUnits == 13_000)
        #expect(snapshot.months.dropLast().last?.spendingMinorUnits == 9_000)
    }

    @Test("Ranks top merchants and averages daily spend")
    func merchantsAndAverage() {
        let snapshot = InsightsCalculator.snapshot(
            transactions: transactions(),
            month: date(2026, 2, 1),
            historyMonths: 3,
            now: date(2026, 3, 15),
            calendar: Self.calendar
        )
        #expect(snapshot.topMerchants.first?.name == "Whole Foods")
        #expect(snapshot.topMerchants.first?.amountMinorUnits == 11_000)
        // February has 28 days; a past month uses the whole month.
        #expect(snapshot.averageDailySpending(now: date(2026, 3, 15), calendar: Self.calendar) == 464)
    }

    @Test("Cumulative spending accumulates by day")
    func cumulative() {
        let points = InsightsCalculator.cumulativeSpending(
            transactions: transactions(),
            month: date(2026, 2, 1),
            now: date(2026, 3, 15),
            calendar: Self.calendar
        )
        #expect(points.count == 28)
        #expect(points[4].amountMinorUnits == 10_000)
        #expect(points.last?.amountMinorUnits == 13_000)
    }

    @Test("Average daily pace uses trailing months with data")
    func averagePace() {
        let pace = InsightsCalculator.averageDailySpend(
            transactions: transactions(),
            before: date(2026, 2, 1),
            months: 1,
            calendar: Self.calendar
        )
        #expect(pace == 9_000 / 31)
    }

    @Test("Snapshot projects month-end and compares like-for-like")
    func projectionAndComparison() {
        let snapshot = InsightsCalculator.snapshot(
            transactions: transactions(),
            month: date(2026, 2, 1),
            historyMonths: 3,
            now: date(2026, 3, 15),
            calendar: Self.calendar
        )
        #expect(snapshot.daysInMonth == 28)
        #expect(snapshot.lastDayWithData == 28)
        #expect(snapshot.currentToDateSpending == 13_000)
        #expect(snapshot.averageDailyPace == 9_000 / 31)
        // A finished month projects to what it actually spent.
        #expect(snapshot.projectedSpending == 13_000)
        #expect(snapshot.topMoverNames.contains("Groceries"))
    }
}

@Suite("Merchant memory")
struct MerchantMemoryTests {
    private let groceries = UUID()
    private let dining = UUID()

    @Test("Majority vote decides the remembered category")
    func majority() {
        let memory = MerchantMemory(samples: [
            MemorySample(merchant: "Blue Bottle", categoryID: dining),
            MemorySample(merchant: "Blue Bottle", categoryID: dining),
            MemorySample(merchant: "Blue Bottle", categoryID: dining),
            MemorySample(merchant: "Blue Bottle", categoryID: groceries),
        ])
        let match = memory.category(forMerchant: "BLUE BOTTLE")
        #expect(match?.categoryID == dining)
        #expect(abs((match?.confidence ?? 0) - 0.75) < 0.0001)
    }

    @Test("Falls back to a similar remembered merchant")
    func similarity() {
        let memory = MerchantMemory(samples: [
            MemorySample(merchant: "Trader Joe's", categoryID: groceries),
        ])
        #expect(memory.category(forMerchant: "Trader Joes")?.categoryID == groceries)
        #expect(memory.categoryBySimilarity(forMerchant: "Trader Joes Market")?.categoryID == groceries)
    }

    @Test("Returns nothing when there is no prior knowledge")
    func empty() {
        let memory = MerchantMemory(samples: [])
        #expect(memory.isEmpty)
        #expect(memory.category(forMerchant: "Anything") == nil)
        #expect(memory.categoryBySimilarity(forMerchant: "Anything") == nil)
    }
}

@Suite("Category suggester")
struct CategorySuggesterTests {
    private let groceries = UUID()
    private let dining = UUID()

    @Test("Rules win over learned history")
    func ruleWins() {
        let memory = MerchantMemory(samples: [
            MemorySample(merchant: "Starbucks", categoryID: groceries),
        ])
        let rule = RuleSnapshot(
            id: UUID(), field: .payee, matchKind: .contains,
            pattern: "starbucks", categoryID: dining
        )
        let suggestion = CategorySuggester.suggest(
            description: "STARBUCKS #123",
            merchant: "Starbucks",
            amountMinorUnits: -675,
            rules: [rule],
            memory: memory
        )
        #expect(suggestion?.categoryID == dining)
        #expect(suggestion?.source == .rule)
    }

    @Test("Uses remembered merchants when no rule matches")
    func memoryWins() {
        let memory = MerchantMemory(samples: [
            MemorySample(merchant: "Whole Foods", categoryID: groceries),
        ])
        let suggestion = CategorySuggester.suggest(
            description: "WHOLE FOODS MARKET",
            merchant: "Whole Foods",
            amountMinorUnits: -8_000,
            rules: [],
            memory: memory
        )
        #expect(suggestion?.categoryID == groceries)
        #expect(suggestion?.source == .memory)
    }

    @Test("Uses similar merchants as a last resort")
    func similar() {
        let memory = MerchantMemory(samples: [
            MemorySample(merchant: "Trader Joe's", categoryID: groceries),
        ])
        let suggestion = CategorySuggester.suggest(
            description: "Trader Joes Market",
            merchant: "Trader Joes Market",
            amountMinorUnits: -1_500,
            rules: [],
            memory: memory
        )
        #expect(suggestion?.categoryID == groceries)
        #expect(suggestion?.source == .similarMerchant)
    }

    @Test("Returns nothing when no layer is confident")
    func noSuggestion() {
        #expect(CategorySuggester.suggest(
            description: "ACME WIDGETS",
            merchant: "Acme",
            amountMinorUnits: -1_000,
            rules: [],
            memory: MerchantMemory(samples: [])
        ) == nil)
    }
}

@Suite("Category name matcher")
struct CategoryNameMatcherTests {
    @Test("Matches exactly and case-insensitively")
    func exact() {
        #expect(CategoryNameMatcher.match("Dining", to: ["Dining", "Groceries"]) == "Dining")
        #expect(CategoryNameMatcher.match("  dining ", to: ["Dining", "Groceries"]) == "Dining")
    }

    @Test("Matches close misspellings")
    func fuzzy() {
        #expect(CategoryNameMatcher.match("Dinning", to: ["Dining", "Groceries"]) == "Dining")
    }

    @Test("Rejects unrelated names")
    func reject() {
        #expect(CategoryNameMatcher.match("Transfer", to: ["Dining", "Groceries"]) == nil)
        #expect(CategoryNameMatcher.match("", to: ["Dining"]) == nil)
    }
}
