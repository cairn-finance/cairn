import Foundation
import Testing
@testable import CairnCore

@Suite("Budget recommendations")
struct BudgetRecommendationTests {
    private let timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    private let months = ["2026-01", "2026-02", "2026-03", "2026-04", "2026-05", "2026-06"]

    @Test("Completed month keys are chronological and skip the current month")
    func completedMonthKeys() {
        #expect(BudgetCalculator.completedMonthKeys(before: "2026-07", count: 6, timeZone: timeZone) == months)
        #expect(BudgetCalculator.completedMonthKeys(before: "2026-01", count: 0, timeZone: timeZone).isEmpty)
    }

    @Test("Suggestions use the active-month median, round up, and exclude ineligible transactions")
    func medianAndTransactionFilters() throws {
        let grocery = category("Groceries", order: 0)
        let income = category("Income", order: 1)
        var transactions: [BudgetTransaction] = []
        let amounts: [Int64] = [-2_000, -4_000, -6_000, -8_000, -10_000, -91_000]
        for (month, amount) in zip(months, amounts) {
            transactions.append(try transaction(month: month, amount: amount, category: grocery))
        }
        transactions.append(try transaction(month: "2026-06", amount: 90_000, category: grocery))
        transactions.append(try transaction(month: "2026-06", amount: -500_000, category: grocery, transfer: true))
        transactions.append(try transaction(month: "2026-06", amount: -500_000, category: grocery, ignored: true))
        transactions.append(try transaction(month: "2026-06", amount: -500_000, category: grocery, pending: true))
        transactions.append(try transaction(month: "2026-06", amount: -500_000, category: income))

        let results = BudgetCalculator.recommendations(
            transactions: transactions,
            categories: [grocery, income],
            currency: .usd,
            monthKeys: months,
            timeZone: timeZone
        )

        let suggestion = try #require(results.first)
        #expect(results.count == 1)
        #expect(suggestion.category.uuid == grocery.uuid)
        #expect(suggestion.monthsWithSpending == 6)
        #expect(suggestion.monthsSampled == 6)
        // Net month totals are 20, 40, 60, 80, 100, and 10 dollars.
        // The median is $50, already on the $5 recommendation step.
        #expect(suggestion.typicalActiveMonthMinorUnits == 5_000)
        #expect(suggestion.suggestedLimitMinorUnits == 5_000)
        #expect(suggestion.monthlySpending.map(\.monthKey) == months)
        #expect(
            suggestion.monthlySpending.map(\.amountMinorUnits)
                == [2_000, 4_000, 6_000, 8_000, 10_000, 1_000]
        )
    }
    @Test("Two active months qualify, but one does not")
    func requiresTwoActiveMonths() throws {
        let dining = category("Dining", order: 0)
        let twoMonths = try [
            transaction(month: "2026-01", amount: -3_000, category: dining),
            transaction(month: "2026-02", amount: -4_000, category: dining),
        ]

        let qualified = BudgetCalculator.recommendations(
            transactions: twoMonths,
            categories: [dining],
            currency: .usd,
            monthKeys: months,
            timeZone: timeZone
        )
        let insufficient = BudgetCalculator.recommendations(
            transactions: [twoMonths[0]],
            categories: [dining],
            currency: .usd,
            monthKeys: months,
            timeZone: timeZone
        )

        #expect(qualified.count == 1)
        #expect(qualified.first?.monthsWithSpending == 2)
        #expect(insufficient.isEmpty)
    }

    @Test("Monthly breakdown includes months with no net spending")
    func monthlyBreakdownIncludesZeroMonths() throws {
        let dining = category("Dining", order: 0)
        let transactions = try [
            transaction(month: "2026-01", amount: -3_000, category: dining),
            transaction(month: "2026-02", amount: -4_000, category: dining),
            transaction(month: "2026-03", amount: -5_000, category: dining),
        ]

        let results = BudgetCalculator.recommendations(
            transactions: transactions,
            categories: [dining],
            currency: .usd,
            monthKeys: months,
            timeZone: timeZone
        )

        let suggestion = try #require(results.first)
        #expect(suggestion.monthsWithSpending == 3)
        #expect(suggestion.monthlySpending.map(\.amountMinorUnits) == [3_000, 4_000, 5_000, 0, 0, 0])
    }

    private func category(_ name: String, order: Int) -> BudgetCategory {
        BudgetCategory(
            uuid: UUID(),
            name: name,
            colorHex: "#8E8E93",
            symbolName: "tag",
            sortOrder: order,
            isArchived: false
        )
    }

    private func transaction(
        month: String,
        amount: Int64,
        category: BudgetCategory,
        transfer: Bool = false,
        ignored: Bool = false,
        pending: Bool = false
    ) throws -> BudgetTransaction {
        let start = try #require(BudgetCalculator.startOfMonth(month, timeZone: timeZone))
        return BudgetTransaction(
            date: start.addingTimeInterval(12 * 60 * 60),
            amountMinorUnits: amount,
            categoryUUID: category.uuid,
            categoryName: category.name,
            isTransfer: transfer,
            isIgnored: ignored,
            isPending: pending
        )
    }
}
