import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("Recurring detection")
struct RecurringDetectionTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    private func input(
        _ id: String,
        _ merchant: String,
        amount: Int64,
        date: Date,
        account: String = "checking",
        accountName: String = "Checking",
        currency: Currency = .usd,
        category: String? = nil,
        isTransfer: Bool = false,
        isIgnored: Bool = false,
        isPending: Bool = false
    ) -> RecurringInput {
        RecurringInput(
            id: id,
            merchantKey: merchant.lowercased(),
            displayName: merchant,
            amountMinorUnits: amount,
            date: date,
            accountID: account,
            accountName: accountName,
            currency: currency,
            categoryName: category,
            isTransfer: isTransfer,
            isIgnored: isIgnored,
            isPending: isPending
        )
    }

    @Test("Detects a monthly subscription with a stable amount")
    func monthlySubscription() throws {
        let inputs = [
            input("1", "Netflix", amount: -1_549, date: date(2026, 1, 5), category: "Entertainment"),
            input("2", "Netflix", amount: -1_549, date: date(2026, 2, 5), category: "Entertainment"),
            input("3", "Netflix", amount: -1_549, date: date(2026, 3, 5), category: "Entertainment"),
            input("4", "Netflix", amount: -1_549, date: date(2026, 4, 5), category: "Entertainment"),
        ]
        let series = try #require(RecurringDetector.detect(inputs, calendar: Self.calendar).first)
        #expect(series.displayName == "Netflix")
        #expect(series.direction == .outgoing)
        #expect(series.cadence == .monthly)
        #expect(series.occurrences == 4)
        #expect(series.averageAmountMinorUnits == -1_549)
        #expect(series.isVariableAmount == false)
        #expect(series.confidence > 0.7)
        #expect(series.categoryName == "Entertainment")
        // The median gap across these months is 31 days, so the next charge
        // lands in early May.
        let gap = Self.calendar.dateComponents(
            [.day], from: series.lastDate, to: series.nextExpectedDate
        ).day ?? 0
        #expect(gap == 31)
    }

    @Test("Detects a two-weekly payment")
    func biweeklyPayment() throws {
        let inputs = [
            input("1", "Lawn Care", amount: -6_000, date: date(2026, 1, 1)),
            input("2", "Lawn Care", amount: -6_000, date: date(2026, 1, 15)),
            input("3", "Lawn Care", amount: -6_000, date: date(2026, 1, 29)),
            input("4", "Lawn Care", amount: -6_000, date: date(2026, 2, 12)),
        ]
        let series = try #require(RecurringDetector.detect(inputs, calendar: Self.calendar).first)
        #expect(series.cadence == .biweekly)
        #expect(series.isSubscription == false)
    }

    @Test("Detects quarterly and yearly charges and their monthly cost")
    func longerCadences() throws {
        let quarterly = RecurringDetector.detect([
            input("1", "Domain Renewal", amount: -30_000, date: date(2025, 1, 5)),
            input("2", "Domain Renewal", amount: -30_000, date: date(2025, 4, 5)),
            input("3", "Domain Renewal", amount: -30_000, date: date(2025, 7, 5)),
            input("4", "Domain Renewal", amount: -30_000, date: date(2025, 10, 5)),
        ], calendar: Self.calendar)
        #expect(quarterly.first?.cadence == .quarterly)
        #expect(abs((quarterly.first?.monthlyEquivalentMinorUnits ?? 0) - 10_034) < 200)

        let yearly = RecurringDetector.detect([
            input("1", "Cloud Storage", amount: -9_999, date: date(2023, 1, 5)),
            input("2", "Cloud Storage", amount: -9_999, date: date(2024, 1, 5)),
            input("3", "Cloud Storage", amount: -9_999, date: date(2025, 1, 5)),
        ], calendar: Self.calendar)
        #expect(yearly.first?.cadence == .yearly)
    }

    @Test("Detects recurring income as an incoming series")
    func recurringIncome() throws {
        let inputs = (1...4).map { month in
            input("p\(month)", "Payroll Deposit", amount: 512_500, date: date(2026, month, 15), category: "Income")
        }
        let series = try #require(RecurringDetector.detect(inputs, calendar: Self.calendar).first)
        #expect(series.direction == .incoming)
        #expect(series.averageAmountMinorUnits == 512_500)
        // Roughly a monthly salary; the exact figure tracks the 31-day gaps.
        #expect(abs(series.monthlyEquivalentMinorUnits - 503_201) < 500)
    }

    @Test("Keeps a variable bill but flags it")
    func variableBill() throws {
        let amounts: [Int64] = [-10_000, -12_000, -9_000, -11_000]
        let inputs = amounts.enumerated().map { index, amount in
            input("b\(index)", "Power Utility", amount: amount, date: date(2026, index + 1, 6))
        }
        let series = try #require(RecurringDetector.detect(inputs, calendar: Self.calendar).first)
        #expect(series.isVariableAmount)
        #expect(series.confidenceLabel == "Possible")
    }

    @Test("Rejects amounts that swing too far to be a regular payment")
    func rejectsErraticAmounts() {
        let inputs = [
            input("1", "Corner Store", amount: -1_000, date: date(2026, 1, 5)),
            input("2", "Corner Store", amount: -3_000, date: date(2026, 2, 5)),
            input("3", "Corner Store", amount: -1_000, date: date(2026, 3, 5)),
            input("4", "Corner Store", amount: -3_000, date: date(2026, 4, 5)),
        ]
        #expect(RecurringDetector.detect(inputs, calendar: Self.calendar).isEmpty)
    }

    @Test("Rejects an irregular rhythm")
    func rejectsIrregular() {
        let inputs = [
            input("1", "Odd Shop", amount: -5_000, date: date(2026, 1, 5)),
            input("2", "Odd Shop", amount: -5_000, date: date(2026, 1, 20)),
            input("3", "Odd Shop", amount: -5_000, date: date(2026, 3, 5)),
            input("4", "Odd Shop", amount: -5_000, date: date(2026, 4, 25)),
        ]
        #expect(RecurringDetector.detect(inputs, calendar: Self.calendar).isEmpty)
    }

    @Test("Does not call routine weekly shopping a subscription")
    func weeklyVaryingIsRejected() {
        let inputs = [
            input("1", "Grocery Run", amount: -6_750, date: date(2026, 1, 3)),
            input("2", "Grocery Run", amount: -12_300, date: date(2026, 1, 10)),
            input("3", "Grocery Run", amount: -8_900, date: date(2026, 1, 17)),
            input("4", "Grocery Run", amount: -15_000, date: date(2026, 1, 24)),
        ]
        #expect(RecurringDetector.detect(inputs, calendar: Self.calendar).isEmpty)
    }

    @Test("Needs at least three charges")
    func minimumOccurrences() {
        let inputs = [
            input("1", "New Service", amount: -1_000, date: date(2026, 1, 5)),
            input("2", "New Service", amount: -1_000, date: date(2026, 2, 5)),
        ]
        #expect(RecurringDetector.detect(inputs, calendar: Self.calendar).isEmpty)
    }

    @Test("Ignores transfers, ignored, and pending rows")
    func exclusions() {
        let inputs = (1...4).map { month in
            input(
                "t\(month)",
                "Move to Savings",
                amount: -50_000,
                date: date(2026, month, 1),
                isTransfer: true
            )
        }
        #expect(RecurringDetector.detect(inputs, calendar: Self.calendar).isEmpty)

        let ignored = (1...4).map { month in
            input("i\(month)", "Hidden Bill", amount: -1_000, date: date(2026, month, 9), isIgnored: true)
        }
        #expect(RecurringDetector.detect(ignored, calendar: Self.calendar).isEmpty)

        let pending = (1...4).map { month in
            input("p\(month)", "Pending Bill", amount: -1_000, date: date(2026, month, 9), isPending: true)
        }
        #expect(RecurringDetector.detect(pending, calendar: Self.calendar).isEmpty)
    }

    @Test("Keeps the same merchant's series separate per account")
    func groupsByAccount() {
        var inputs: [RecurringInput] = []
        for month in 1...4 {
            inputs.append(input(
                "a\(month)", "Cloud Plan", amount: -1_000, date: date(2026, month, 2),
                account: "A", accountName: "Account A"
            ))
            inputs.append(input(
                "b\(month)", "Cloud Plan", amount: -2_000, date: date(2026, month, 3),
                account: "B", accountName: "Account B"
            ))
        }
        let series = RecurringDetector.detect(inputs, calendar: Self.calendar)
        #expect(series.count == 2)
        #expect(Set(series.map(\.accountNames.first)) == ["Account A", "Account B"])
    }

    @Test("Orders outgoing before incoming, largest monthly cost first")
    func ordering() {
        var inputs: [RecurringInput] = []
        for month in 1...4 {
            inputs.append(input("small\(month)", "Small Plan", amount: -500, date: date(2026, month, 4)))
            inputs.append(input("big\(month)", "Big Plan", amount: -5_000, date: date(2026, month, 4)))
            inputs.append(input("pay\(month)", "Payroll", amount: 400_000, date: date(2026, month, 15)))
        }
        let series = RecurringDetector.detect(inputs, calendar: Self.calendar)
        #expect(series.map(\.displayName) == ["Big Plan", "Small Plan", "Payroll"])
    }
}

@Suite("Recurring analyzer")
@MainActor
struct RecurringAnalyzerTests {
    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        return (result.container, result.container.mainContext)
    }

    private func date(_ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day)) ?? .distantPast
    }

    @Test("Maps persisted transactions, carrying category and account")
    func mapsTransactions() async throws {
        let (container, context) = try makeContext()
        let category = Category(name: "Entertainment", symbolName: "tv.fill", colorHex: "#AF52DE", sortOrder: 0)
        context.insert(category)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)

        for month in 1...4 {
            let transaction = LedgerTransaction(
                bankTransactionID: "S\(month)",
                payeeDescription: "Streaming Service",
                amountMinorUnits: -1_299
            )
            transaction.account = account
            transaction.accountIDIndex = "A1"
            transaction.postedDate = date(month, 5)
            transaction.normalizedMerchant = MerchantNormalizer.normalize("Streaming Service")
            transaction.userCategory = category
            context.insert(transaction)
        }
        try context.save()

        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        let series = try #require(RecurringDetector.detect(transactions: transactions).first)
        #expect(series.cadence == .monthly)
        #expect(series.categoryName == "Entertainment")
        #expect(series.categorySymbolName == "tv.fill")
        #expect(series.accountNames == ["Checking"])
        #expect(series.transactionIDs.contains("A1|S1"))
        _ = container
    }

    @Test("A transfer run produces no series")
    func transfersExcluded() async throws {
        let (container, context) = try makeContext()
        let transfers = Category(
            name: "Transfers",
            symbolName: "arrow.left.arrow.right",
            colorHex: "#32ADE6",
            sortOrder: 0,
            isSystem: true
        )
        context.insert(transfers)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)

        for month in 1...4 {
            let transaction = LedgerTransaction(
                bankTransactionID: "T\(month)",
                payeeDescription: "Transfer to Savings",
                amountMinorUnits: -50_000
            )
            transaction.account = account
            transaction.accountIDIndex = "A1"
            transaction.postedDate = date(month, 1)
            transaction.normalizedMerchant = MerchantNormalizer.normalize("Transfer to Savings")
            transaction.userCategory = transfers
            context.insert(transaction)
        }
        try context.save()

        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(RecurringDetector.detect(transactions: transactions).isEmpty)
        _ = container
    }
}
