import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("Budget management")
@MainActor
struct BudgetManagementTests {
    private let timeZone = TimeZone(secondsFromGMT: 0) ?? .current

    @Test("Remaining compares planned limits with spending in planned categories")
    func remainingExcludesUnbudgetedSpending() throws {
        let groceries = budgetCategory("Groceries")
        let housing = budgetCategory("Housing")
        let setting = budgetSetting(categoryUUID: groceries.uuid, amount: 20_000)
        let start = try #require(BudgetCalculator.startOfMonth("2026-09", timeZone: timeZone))
        let transactions = [
            BudgetTransaction(
                date: start, amountMinorUnits: -10_000,
                categoryUUID: groceries.uuid, categoryName: groceries.name,
                isTransfer: false, isIgnored: false, isPending: false
            ),
            BudgetTransaction(
                date: start, amountMinorUnits: -100_000,
                categoryUUID: housing.uuid, categoryName: housing.name,
                isTransfer: false, isIgnored: false, isPending: false
            ),
        ]

        let result = BudgetCalculator.snapshot(
            transactions: transactions,
            categories: [groceries, housing],
            settings: [setting],
            monthKey: "2026-09", currency: .usd, timeZone: timeZone
        )

        #expect(result.plannedMinorUnits == 20_000)
        #expect(result.budgetedSpentMinorUnits == 10_000)
        #expect(result.spentMinorUnits == 110_000)
        #expect(result.unbudgetedMinorUnits == 100_000)
        #expect(result.remainingMinorUnits == 10_000)
    }

    @Test("An override controls one month and preserves the recurring limit")
    func monthOverrideResolution() {
        let categoryID = UUID()
        let recurring = budgetSetting(categoryUUID: categoryID, amount: 20_000)
        let override = budgetSetting(
            categoryUUID: categoryID, amount: 0, month: "2026-09",
            isMonthOverride: true, isEnabled: false
        )

        let september = BudgetCalculator.effectiveSettings(
            [recurring, override], monthKey: "2026-09", currency: .usd
        )
        let october = BudgetCalculator.effectiveSettings(
            [recurring, override], monthKey: "2026-10", currency: .usd
        )

        #expect(september[categoryID]?.isEnabled == false)
        #expect(october[categoryID]?.amountMinorUnits == 20_000)
    }

    @Test("A recurring edit replaces a conflicting override for its first month")
    func recurringEditReplacesOverride() async throws {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        let category = Category(name: "Groceries")
        result.container.mainContext.insert(category)
        try result.container.mainContext.save()
        let engine = SyncEngine(modelContainer: result.container)

        try await engine.setBudgetLimit(
            categoryUUID: category.uuid, currency: .usd, monthKey: "2026-09",
            amountMinorUnits: 30_000, isMonthOverride: true,
            isEnabled: true, timeZoneIdentifier: "UTC"
        )
        try await engine.setBudgetLimit(
            categoryUUID: category.uuid, currency: .usd, monthKey: "2026-09",
            amountMinorUnits: 20_000, isMonthOverride: false,
            isEnabled: true, timeZoneIdentifier: "UTC"
        )

        let rows = try ModelContext(result.container).fetch(FetchDescriptor<CategoryBudget>())
        #expect(rows.count == 1)
        #expect(rows.first?.amountMinorUnits == 20_000)
        #expect(rows.first?.isMonthOverride == false)
    }

    @Test("Starting recommendations can replace a disabled limit")
    func recommendationReplacesDisabledLimit() async throws {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        let category = Category(name: "Groceries")
        result.container.mainContext.insert(category)
        try result.container.mainContext.save()
        let engine = SyncEngine(modelContainer: result.container)

        try await engine.setBudgetLimit(
            categoryUUID: category.uuid, currency: .usd, monthKey: "2026-09",
            amountMinorUnits: 0, isMonthOverride: true,
            isEnabled: false, timeZoneIdentifier: "UTC"
        )
        try await engine.applyBudgetRecommendations(
            [BudgetLimitSelection(categoryUUID: category.uuid, amountMinorUnits: 25_000)],
            currency: .usd, monthKey: "2026-09", timeZoneIdentifier: "UTC"
        )

        let rows = try ModelContext(result.container).fetch(FetchDescriptor<CategoryBudget>())
        #expect(rows.count == 1)
        #expect(rows.first?.amountMinorUnits == 25_000)
        #expect(rows.first?.isEnabled == true)
        #expect(rows.first?.isMonthOverride == false)
    }

    @Test("Reset removes all limit rules while preserving ledger data")
    func resetBudgetSettings() async throws {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        let context = result.container.mainContext
        let category = Category(name: "Groceries")
        let account = Account(bankAccountID: "test-account", name: "Checking", currency: .usd)
        let transaction = LedgerTransaction(
            bankTransactionID: "test-transaction", payeeDescription: "Groceries", amountMinorUnits: -1_000
        )
        transaction.accountIDIndex = account.bankAccountID
        transaction.account = account
        context.insert(category)
        context.insert(account)
        context.insert(transaction)
        try context.save()

        let engine = SyncEngine(modelContainer: result.container)
        try await engine.setBudgetLimit(
            categoryUUID: category.uuid, currency: .usd, monthKey: "2026-09",
            amountMinorUnits: 20_000, isMonthOverride: false,
            isEnabled: true, timeZoneIdentifier: "UTC"
        )
        try await engine.setBudgetLimit(
            categoryUUID: category.uuid, currency: .usd, monthKey: "2026-10",
            amountMinorUnits: 15_000, isMonthOverride: true,
            isEnabled: true, timeZoneIdentifier: "UTC"
        )
        try await engine.setBudgetLimit(
            categoryUUID: category.uuid, currency: Currency(code: "EUR"), monthKey: "2026-09",
            amountMinorUnits: 18_000, isMonthOverride: false,
            isEnabled: true, timeZoneIdentifier: "UTC"
        )

        try await engine.resetBudgetSettings()

        let verificationContext = ModelContext(result.container)
        #expect(try verificationContext.fetch(FetchDescriptor<CategoryBudget>()).isEmpty)
        #expect(try verificationContext.fetch(FetchDescriptor<CairnSchemaV3.Category>()).count == 1)
        #expect(try verificationContext.fetch(FetchDescriptor<Account>()).count == 1)
        #expect(try verificationContext.fetch(FetchDescriptor<LedgerTransaction>()).count == 1)
    }

    private func budgetCategory(_ name: String) -> BudgetCategory {
        BudgetCategory(
            uuid: UUID(), name: name, colorHex: "#8E8E93",
            symbolName: "tag", sortOrder: 0, isArchived: false
        )
    }

    private func budgetSetting(
        categoryUUID: UUID,
        amount: Int64,
        month: String = "2026-08",
        isMonthOverride: Bool = false,
        isEnabled: Bool = true
    ) -> BudgetSetting {
        BudgetSetting(
            uuid: UUID(), categoryUUID: categoryUUID, currency: .usd,
            monthKey: month, amountMinorUnits: amount,
            isMonthOverride: isMonthOverride, isEnabled: isEnabled,
            timeZoneIdentifier: "UTC", modifiedAt: .now
        )
    }
}
