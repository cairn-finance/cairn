import Foundation
import SwiftData
import Testing
@testable import CairnCore

struct FinancialWidgetSnapshotTests {
    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    private func amount(_ values: [FinancialWidgetAmount], code: String) -> Int64? {
        values.first { $0.currency.code == code }?.amountMinorUnits
    }

    @Test("Net worth follows included accounts and MTD spend stays currency-safe")
    func buildsFinancialSnapshot() {
        let eur = Currency(code: "EUR")
        let accounts = [
            FinancialWidgetAccount(currency: .usd, balanceMinorUnits: 10_000, isHidden: false, includeInNetWorth: true),
            FinancialWidgetAccount(currency: eur, balanceMinorUnits: 20_000, isHidden: false, includeInNetWorth: true),
            FinancialWidgetAccount(currency: .usd, balanceMinorUnits: 90_000, isHidden: true, includeInNetWorth: true),
            FinancialWidgetAccount(currency: .usd, balanceMinorUnits: 80_000, isHidden: false, includeInNetWorth: false),
        ]
        let transactions = [
            FinancialWidgetTransaction(
                currency: .usd, amountMinorUnits: -1_000, effectiveDate: date(2026, 5, 2),
                isPending: false, isIgnored: false, countsAsTransfer: false
            ),
            FinancialWidgetTransaction(
                currency: eur, amountMinorUnits: -2_000, effectiveDate: date(2026, 5, 7),
                isPending: false, isIgnored: false, countsAsTransfer: false
            ),
            FinancialWidgetTransaction(
                currency: .usd, amountMinorUnits: -3_000, effectiveDate: date(2026, 5, 8),
                isPending: true, isIgnored: false, countsAsTransfer: false
            ),
            FinancialWidgetTransaction(
                currency: .usd, amountMinorUnits: -4_000, effectiveDate: date(2026, 5, 9),
                isPending: false, isIgnored: true, countsAsTransfer: false
            ),
            FinancialWidgetTransaction(
                currency: .usd, amountMinorUnits: -5_000, effectiveDate: date(2026, 5, 10),
                isPending: false, isIgnored: false, countsAsTransfer: true
            ),
            FinancialWidgetTransaction(
                currency: .usd, amountMinorUnits: -6_000, effectiveDate: date(2026, 4, 30),
                isPending: false, isIgnored: false, countsAsTransfer: false
            ),
        ]
        let now = date(2026, 5, 20, hour: 12)

        let snapshot = FinancialWidgetSnapshotBuilder.make(
            accounts: accounts,
            transactions: transactions,
            homeCurrency: eur,
            now: now,
            calendar: calendar()
        )

        #expect(snapshot.primaryCurrency == eur)
        #expect(snapshot.netWorth.count == 2)
        #expect(amount(snapshot.netWorth, code: "USD") == 10_000)
        #expect(amount(snapshot.netWorth, code: "EUR") == 20_000)
        #expect(snapshot.monthToDateSpend.count == 2)
        #expect(amount(snapshot.monthToDateSpend, code: "USD") == 1_000)
        #expect(amount(snapshot.monthToDateSpend, code: "EUR") == 2_000)
        #expect(snapshot.includesCurrentMonth(at: now, calendar: calendar()))
        #expect(snapshot.isFresh(at: now.addingTimeInterval(60 * 60)))
        #expect(!snapshot.isFresh(at: now.addingTimeInterval(27 * 60 * 60)))
        #expect(!snapshot.includesCurrentMonth(at: date(2026, 6, 1), calendar: calendar()))
    }

    @MainActor
    @Test("Widget fetcher snapshots the saved accounts and posted expenses")
    func fetchesSavedData() async throws {
        let container = try ModelContainerFactory.make(mode: .local, inMemory: true).container
        let context = container.mainContext
        let account = Account(bankAccountID: "checking", name: "Checking", currency: .usd)
        account.balanceMinorUnits = 25_000
        context.insert(account)
        let settings = AppSettings()
        settings.homeCurrencyCode = "USD"
        context.insert(settings)

        let expense = LedgerTransaction(bankTransactionID: "posted", payeeDescription: "Coffee", amountMinorUnits: -1_200)
        expense.account = account
        expense.accountIDIndex = account.bankAccountID
        expense.postedDate = date(2026, 5, 10)
        context.insert(expense)
        let pending = LedgerTransaction(bankTransactionID: "pending", payeeDescription: "Coffee", amountMinorUnits: -500)
        pending.account = account
        pending.accountIDIndex = account.bankAccountID
        pending.isPending = true
        pending.transactedAt = date(2026, 5, 11)
        context.insert(pending)
        try context.save()

        let fetcher = await Task.detached {
            FinancialWidgetFetcher(modelContainer: container)
        }.value
        let snapshot = try await fetcher.snapshot(at: date(2026, 5, 20, hour: 12), calendar: calendar())

        #expect(snapshot.netWorth.first?.amountMinorUnits == 25_000)
        #expect(snapshot.monthToDateSpend.first?.amountMinorUnits == 1_200)
    }
}

struct MerchantSpendSummaryTests {
    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    private func transaction(
        _ merchantKey: String = "acme",
        currency: Currency = .usd,
        amount: Int64,
        date: Date,
        isPending: Bool = false,
        isIgnored: Bool = false,
        isTransfer: Bool = false
    ) -> MerchantSpendTransaction {
        MerchantSpendTransaction(
            merchantKey: merchantKey,
            currency: currency,
            amountMinorUnits: amount,
            effectiveDate: date,
            isPending: isPending,
            isIgnored: isIgnored,
            countsAsTransfer: isTransfer
        )
    }

    private func amount(_ values: [FinancialWidgetAmount], code: String) -> Int64? {
        values.first { $0.currency.code == code }?.amountMinorUnits
    }

    @Test("Weekly, monthly, and yearly totals include only posted merchant spending")
    func totalsByPeriod() {
        let transactions = [
            transaction(amount: -1_250, date: date(2026, 5, 19)),
            transaction(amount: -2_500, date: date(2026, 5, 8)),
            transaction(currency: Currency(code: "EUR"), amount: -300, date: date(2026, 4, 30)),
            transaction(amount: -9_000, date: date(2025, 12, 31)),
            transaction(amount: -500, date: date(2026, 5, 19), isPending: true),
            transaction(amount: -600, date: date(2026, 5, 19), isIgnored: true),
            transaction(amount: -700, date: date(2026, 5, 19), isTransfer: true),
            transaction(amount: 800, date: date(2026, 5, 19)),
            transaction("another", amount: -1_000, date: date(2026, 5, 19)),
            transaction(amount: -1_100, date: date(2026, 5, 21)),
        ]

        let summary = MerchantSpendSummaryBuilder.make(
            merchantKey: "acme",
            transactions: transactions,
            now: date(2026, 5, 20, hour: 12),
            calendar: calendar()
        )

        #expect(amount(summary.week, code: "USD") == 1_250)
        #expect(summary.week.count == 1)
        #expect(amount(summary.month, code: "USD") == 3_750)
        #expect(summary.month.count == 1)
        #expect(amount(summary.year, code: "USD") == 3_750)
        #expect(amount(summary.year, code: "EUR") == 300)
        #expect(summary.year.count == 2)
        #expect(summary.weekStart == date(2026, 5, 18))
        #expect(summary.monthStart == date(2026, 5, 1))
        #expect(summary.yearStart == date(2026, 1, 1))
    }

    @Test("Merchant filter matches the exact normalized identity")
    func merchantFilter() {
        let matching = TransactionRowValue(
            id: "1", persistentID: nil, payeeDescription: "Coffee Shop #1234", merchantKey: "coffee shop",
            amountMinorUnits: -100, currency: .usd, effectiveDate: .now,
            isPending: false, isIgnored: false, isTransfer: false, countsAsTransfer: false,
            categoryName: nil, categorySymbolName: nil, categoryColorHex: nil,
            accountName: nil, tagNames: []
        )
        let other = TransactionRowValue(
            id: "2", persistentID: nil, payeeDescription: "Coffee Shop Notes", merchantKey: "different merchant",
            amountMinorUnits: -100, currency: .usd, effectiveDate: .now,
            isPending: false, isIgnored: false, isTransfer: false, countsAsTransfer: false,
            categoryName: nil, categorySymbolName: nil, categoryColorHex: nil,
            accountName: nil, tagNames: []
        )
        let filter = TransactionFilter(merchantKey: "coffee shop")

        #expect(TransactionRefinement.matches(matching, filter: filter))
        #expect(!TransactionRefinement.matches(other, filter: filter))
        #expect(filter.isActive)
        #expect(filter.namespace != TransactionFilter().namespace)
    }

    @MainActor
    @Test("Merchant fetcher groups saved rows by normalized merchant")
    func fetchesMerchantRows() async throws {
        let container = try ModelContainerFactory.make(mode: .local, inMemory: true).container
        let context = container.mainContext
        let account = Account(bankAccountID: "checking", name: "Checking", currency: .usd)
        context.insert(account)

        let first = LedgerTransaction(bankTransactionID: "one", payeeDescription: "Coffee Roasters #1234", amountMinorUnits: -800)
        first.normalizedMerchant = "Coffee Roasters"
        first.account = account
        first.accountIDIndex = account.bankAccountID
        first.postedDate = date(2026, 5, 19)
        context.insert(first)
        let second = LedgerTransaction(bankTransactionID: "two", payeeDescription: "Coffee Roasters", amountMinorUnits: -200)
        second.normalizedMerchant = "Coffee Roasters"
        second.account = account
        second.accountIDIndex = account.bankAccountID
        second.postedDate = date(2026, 5, 8)
        context.insert(second)
        try context.save()

        let fetcher = await Task.detached {
            MerchantSpendFetcher(modelContainer: container)
        }.value
        let summary = try await fetcher.summary(
            for: "coffee roasters",
            at: date(2026, 5, 20, hour: 12),
            calendar: calendar()
        )

        #expect(amount(summary.week, code: "USD") == 800)
        #expect(amount(summary.month, code: "USD") == 1_000)
        #expect(amount(summary.year, code: "USD") == 1_000)
    }
}
