import Foundation
import CoreData
import SwiftData
import Testing
@testable import CairnCore

@Suite("Personal tracking calculations")
struct PersonalTrackingCalculationTests {
    private let now = Date(timeIntervalSince1970: 1_792_800_000)

    @Test("Manual amounts reject excess precision and accept locale decimal separators")
    func amountPrecision() {
        #expect(PersonalTrackingAmount.parse("1.001", currency: .usd) == nil)
        #expect(PersonalTrackingAmount.parse("1.5", currency: .simpleFIN("JPY")) == nil)
        #expect(PersonalTrackingAmount.parse("12,34", currency: .usd, locale: Locale(identifier: "de_DE")) == 1_234)
        #expect(PersonalTrackingAmount.parse("12.34", currency: .usd, locale: Locale(identifier: "de_DE")) == 1_234)
        #expect(PersonalTrackingAmount.parse("100", currency: .simpleFIN("JPY")) == 100)
    }

    @Test("An equal split preserves every minor unit", arguments: [2, 3, 7, 20])
    func equalSplit(count: Int) throws {
        let shares = try SharedExpenseCalculator.equalShares(total: 101, count: count)
        #expect(shares.reduce(0, +) == 101)
        #expect((shares.max() ?? 0) - (shares.min() ?? 0) <= 1)
    }

    @Test("The payer is owed each other share and partial payments reduce only that person's balance")
    func partialPayments() throws {
        let expense = sharedFixture()
        let person = expense.participants[1]
        let payment = SharedPaymentInput(
            expenseID: expense.uuid, participantID: person.id, amountMinorUnits: 1_000, date: now
        )
        let balances = try SharedExpenseCalculator.balances(for: expense, payments: [payment])
        #expect(balances.count == 2)
        #expect(balances[0].owedToMe)
        #expect(balances[0].outstandingMinorUnits == 3_000)
        #expect(balances[1].outstandingMinorUnits == 4_000)
    }

    @Test("When someone else paid, only my share is owed to that payer")
    func someoneElsePaid() throws {
        var expense = sharedFixture()
        expense.payerID = expense.participants[1].id
        let balances = try SharedExpenseCalculator.balances(for: expense, payments: [])
        #expect(balances.count == 1)
        #expect(balances[0].participantID == expense.payerID)
        #expect(!balances[0].owedToMe)
        #expect(balances[0].outstandingMinorUnits == 4_000)
    }

    @Test("Invalid shares, duplicate identities, and overflow are rejected")
    func invalidSplits() {
        var expense = sharedFixture()
        expense.participants[1].shareMinorUnits = 1
        #expect(throws: PersonalTrackingError.invalidSplit) { try SharedExpenseCalculator.validate(expense) }
        expense = sharedFixture()
        expense.participants[1].id = expense.participants[0].id
        #expect(throws: PersonalTrackingError.invalidSplit) { try SharedExpenseCalculator.validate(expense) }
        expense = sharedFixture()
        expense.participants[0].shareMinorUnits = .max
        #expect(throws: PersonalTrackingError.invalidAmount) { try SharedExpenseCalculator.validate(expense) }
    }

    @Test("Overpayments and payments to the wrong participant are refused")
    func invalidPayments() {
        let expense = sharedFixture()
        let tooMuch = SharedPaymentInput(
            expenseID: expense.uuid, participantID: expense.participants[1].id, amountMinorUnits: 4_001
        )
        #expect(throws: PersonalTrackingError.overpayment) {
            try SharedExpenseCalculator.balances(for: expense, payments: [tooMuch])
        }
        let wrongPerson = SharedPaymentInput(expenseID: expense.uuid, participantID: UUID(), amountMinorUnits: 1)
        #expect(throws: PersonalTrackingError.invalidParticipant) {
            try SharedExpenseCalculator.balances(for: expense, payments: [wrongPerson])
        }
    }

    @Test("A fund derives its balance from confirmed history and rounds its monthly suggestion up")
    func fundSummary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 30)))
        let fund = SinkingFundInput(name: "Insurance", targetMinorUnits: 120_001, targetDate: end, timeZoneIdentifier: "UTC")
        let opening = SinkingFundEntryInput(fundID: fund.uuid, amountMinorUnits: 30_000, kind: .opening, date: start)
        let summary = try SinkingFundCalculator.summary(for: fund, entries: [opening], now: start)
        #expect(summary.fundedMinorUnits == 30_000)
        #expect(summary.remainingMinorUnits == 90_001)
        #expect(summary.suggestedMonthlyMinorUnits == 10_001)
        #expect(summary.contributedThisMonthMinorUnits == 0)
    }

    @Test("Withdrawals and corrections affect funding but not monthly contribution totals")
    func withdrawals() throws {
        let fund = SinkingFundInput(name: "Repairs", targetMinorUnits: 10_000)
        let entries = [
            SinkingFundEntryInput(fundID: fund.uuid, amountMinorUnits: 5_000, date: now.addingTimeInterval(-30)),
            SinkingFundEntryInput(
                fundID: fund.uuid, amountMinorUnits: -1_000, kind: .withdrawal, date: now.addingTimeInterval(-20)
            ),
            SinkingFundEntryInput(fundID: fund.uuid, amountMinorUnits: 500, kind: .correction, date: now),
        ]
        let summary = try SinkingFundCalculator.summary(for: fund, entries: entries, now: now)
        #expect(summary.fundedMinorUnits == 4_500)
        #expect(summary.contributedThisMonthMinorUnits == 5_000)
        #expect(summary.suggestedMonthlyMinorUnits == nil)
    }

    @Test("Backdated overdrafts, future allocations, and arithmetic overflow are rejected")
    func invalidFundHistory() {
        let fund = SinkingFundInput(name: "Repairs", targetMinorUnits: 10_000)
        let debit = SinkingFundEntryInput(fundID: fund.uuid, amountMinorUnits: -1, kind: .withdrawal, date: now)
        #expect(throws: PersonalTrackingError.insufficientFunds) {
            try SinkingFundCalculator.summary(for: fund, entries: [debit], now: now)
        }
        let future = SinkingFundEntryInput(fundID: fund.uuid, amountMinorUnits: 1, date: now.addingTimeInterval(1))
        #expect(throws: PersonalTrackingError.invalidDate) {
            try SinkingFundCalculator.summary(for: fund, entries: [future], now: now)
        }
        let maximum = SinkingFundEntryInput(fundID: fund.uuid, amountMinorUnits: .max, date: now)
        let extra = SinkingFundEntryInput(fundID: fund.uuid, amountMinorUnits: 1, date: now)
        #expect(throws: PersonalTrackingError.invalidAmount) {
            try SinkingFundCalculator.summary(for: fund, entries: [maximum, extra], now: now)
        }
    }

    @Test("An overdue target asks for the remaining amount and overfunding has no negative remainder")
    func overdueAndOverfunded() throws {
        let fund = SinkingFundInput(name: "Holiday", targetMinorUnits: 100, targetDate: now.addingTimeInterval(-90 * 86_400))
        #expect(try SinkingFundCalculator.summary(for: fund, entries: [], now: now).suggestedMonthlyMinorUnits == 100)
        let entry = SinkingFundEntryInput(fundID: fund.uuid, amountMinorUnits: 200, date: now)
        let summary = try SinkingFundCalculator.summary(for: fund, entries: [entry], now: now)
        #expect(summary.remainingMinorUnits == 0)
        #expect(summary.suggestedMonthlyMinorUnits == 0)
        #expect(summary.progress == 1)
    }

    @Test("Month boundaries use the fund's saved time zone")
    func timeZone() throws {
        let formatter = ISO8601DateFormatter()
        let atBoundary = try #require(formatter.date(from: "2026-02-01T01:00:00Z"))
        let january = try #require(formatter.date(from: "2026-01-15T12:00:00Z"))
        let fund = SinkingFundInput(name: "Repairs", targetMinorUnits: 1_000, timeZoneIdentifier: "America/Los_Angeles")
        let entry = SinkingFundEntryInput(fundID: fund.uuid, amountMinorUnits: 100, date: january)
        #expect(try SinkingFundCalculator.summary(for: fund, entries: [entry], now: atBoundary)
            .contributedThisMonthMinorUnits == 100)
    }
}

@Suite("Personal tracking persistence")
@MainActor
struct PersonalTrackingPersistenceTests {
    @Test("Every new financial attribute is encrypted and the models have CloudKit-compatible defaults")
    func encryptedSchema() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: CairnSchemaV6.models))
        let names: Set<String> = ["SharedExpense", "SharedExpensePayment", "SinkingFund", "SinkingFundEntry"]
        let entities = model.entities.filter { names.contains($0.name ?? "") }
        #expect(entities.count == 4)
        for entity in entities {
            #expect(entity.uniquenessConstraints.isEmpty)
            for attribute in entity.attributesByName.values {
                if !["uuid", "createdAt", "modifiedAt"].contains(attribute.name) {
                    #expect(attribute.allowsCloudEncryption, "\(entity.name ?? "").\(attribute.name)")
                }
                #expect(attribute.isOptional || attribute.defaultValue != nil)
            }
        }
    }

    @Test("Recorded history locks currency identity, including the minor-unit exponent")
    func currencyIdentity() async throws {
        let container = try ModelContainerFactory.make(mode: .local, inMemory: true).container
        let engine = SyncEngine(modelContainer: container)
        var fund = SinkingFundInput(name: "Repairs", targetMinorUnits: 1_000)
        try await engine.saveSinkingFund(fund, openingMinorUnits: 100)
        fund.currency.exponent = 0
        await #expect(throws: PersonalTrackingError.invalidCurrency) { try await engine.saveSinkingFund(fund) }
        var expense = sharedFixture()
        try await engine.saveSharedExpense(expense)
        try await engine.addSharedPayment(SharedPaymentInput(
            expenseID: expense.uuid, participantID: expense.participants[1].id, amountMinorUnits: 1
        ))
        expense.currency.exponent = 0
        await #expect(throws: PersonalTrackingError.invalidCurrency) { try await engine.saveSharedExpense(expense) }
    }

    @Test("Both trackers work without accounts and export every split and history entry")
    func noAccountsAndExport() async throws {
        let container = try ModelContainerFactory.make(mode: .local, inMemory: true).container
        let engine = SyncEngine(modelContainer: container)
        var expense = sharedFixture()
        expense.currency = Currency(code: "https://example.com/points", exponent: 0, isCustom: true,
                                    customName: "Points", customAbbreviation: "pts")
        try await engine.saveSharedExpense(expense)
        let payment = SharedPaymentInput(
            expenseID: expense.uuid, participantID: expense.participants[1].id, amountMinorUnits: 1_000
        )
        try await engine.addSharedPayment(payment)
        try await engine.addSharedPayment(payment)
        let fund = SinkingFundInput(name: "Insurance", targetMinorUnits: 120_000)
        try await engine.saveSinkingFund(fund, openingMinorUnits: 30_000)
        let contribution = SinkingFundEntryInput(fundID: fund.uuid, amountMinorUnits: 10_000)
        try await engine.addSinkingFundEntry(contribution)
        try await engine.addSinkingFundEntry(contribution)
        let data = try await engine.exportPersonalTrackingJSON()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(PersonalTrackingArchive.self, from: data)
        #expect(archive.expenses.count == 1)
        #expect(archive.expenses.first?.currency == expense.currency)
        #expect(archive.expenses.first?.participants == expense.participants)
        #expect(archive.payments.count == 1)
        #expect(archive.entries.count == 2)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Account>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<LedgerTransaction>()) == 0)
    }

    @Test("Attaching bank evidence leaves balances, transactions, and reporting unchanged")
    func attachmentsDoNotChangeLedger() async throws {
        let container = try ModelContainerFactory.make(mode: .local, inMemory: true).container
        let context = container.mainContext
        let account = Account(bankAccountID: "tracking-account", name: "Checking")
        account.balanceMinorUnits = 123_456
        let transaction = LedgerTransaction(bankTransactionID: "dinner", payeeDescription: "Dinner", amountMinorUnits: -12_000)
        transaction.account = account
        transaction.accountIDIndex = account.bankAccountID
        transaction.postedDate = .now
        context.insert(account)
        context.insert(transaction)
        try context.save()
        let engine = SyncEngine(modelContainer: container)
        var expense = sharedFixture()
        expense.bankLink = TrackingBankLink(accountIDIndex: account.bankAccountID, bankTransactionID: "dinner")
        try await engine.saveSharedExpense(expense)
        #expect(account.balanceMinorUnits == 123_456)
        #expect(transaction.amountMinorUnits == -12_000)
        #expect(!transaction.isTransfer)
        #expect(transaction.settlementID == nil)
        #expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()) == 1)
        let fetcher = BudgetFetcher(modelContainer: container)
        let rows = try await fetcher.budgetTransactions(
            scopes: [BudgetAccountScope(bankAccountID: account.bankAccountID)],
            from: Date.now.addingTimeInterval(-86_400), to: Date.now.addingTimeInterval(86_400)
        )
        #expect(rows.count == 1)
        #expect(rows.first?.amountMinorUnits == -12_000)

        var duplicate = sharedFixture()
        duplicate.bankLink = expense.bankLink
        await #expect(throws: PersonalTrackingError.bankRowAlreadyLinked) { try await engine.saveSharedExpense(duplicate) }
        var changed = expense
        changed.totalMinorUnits = 15_000
        changed.participants = changed.participants.map {
            ExpenseParticipant(id: $0.id, name: $0.name, shareMinorUnits: 5_000, isMe: $0.isMe)
        }
        await #expect(throws: PersonalTrackingError.invalidBankLink) { try await engine.saveSharedExpense(changed) }

        context.delete(transaction)
        try context.save()
        expense.title = "Dinner after deleting the bank row"
        try await engine.saveSharedExpense(expense)
        #expect(try context.fetchCount(FetchDescriptor<SharedExpense>()) == 1)
    }

    @Test("Invalid and pending bank references cannot be saved")
    func rejectsInvalidBankLinks() async throws {
        let container = try ModelContainerFactory.make(mode: .local, inMemory: true).container
        let context = container.mainContext
        let account = Account(bankAccountID: "A", name: "Checking", currency: .usd)
        let transaction = LedgerTransaction(bankTransactionID: "T", amountMinorUnits: -12_000)
        transaction.account = account
        transaction.accountIDIndex = "A"
        transaction.isPending = true
        context.insert(account)
        context.insert(transaction)
        try context.save()
        let engine = SyncEngine(modelContainer: container)
        var expense = sharedFixture()
        expense.bankLink = TrackingBankLink(accountIDIndex: "A", bankTransactionID: "T")
        await #expect(throws: PersonalTrackingError.invalidBankLink) { try await engine.saveSharedExpense(expense) }
        #expect(try context.fetchCount(FetchDescriptor<SharedExpense>()) == 0)
    }

    @Test("A manual repayment can attach and detach bank evidence later", arguments: [true, false])
    func attachesRepaymentLater(paidByMe: Bool) async throws {
        let container = try ModelContainerFactory.make(mode: .local, inMemory: true).container
        let engine = SyncEngine(modelContainer: container)
        var expense = sharedFixture()
        if !paidByMe { expense.payerID = expense.participants[1].id }
        try await engine.saveSharedExpense(expense)
        let payment = SharedPaymentInput(
            expenseID: expense.uuid, participantID: expense.participants[1].id, amountMinorUnits: 1_000
        )
        try await engine.addSharedPayment(payment)
        let account = Account(bankAccountID: "A", name: "Checking")
        let bankAmount: Int64 = paidByMe ? 1_000 : -1_000
        let row = LedgerTransaction(bankTransactionID: "payment", amountMinorUnits: bankAmount)
        row.account = account
        row.accountIDIndex = "A"
        container.mainContext.insert(account)
        container.mainContext.insert(row)
        try container.mainContext.save()
        let link = TrackingBankLink(accountIDIndex: "A", bankTransactionID: "payment")
        try await engine.attachSharedPayment(payment.uuid, to: link)
        let fresh = ModelContext(container)
        let recorded = try #require(fresh.fetch(FetchDescriptor<SharedExpensePayment>()).first)
        #expect(try recorded.input.bankLink == link)
        #expect(recorded.amountMinorUnits == 1_000)
        #expect(row.amountMinorUnits == bankAmount)
        try await engine.attachSharedPayment(payment.uuid, to: nil)
        let refetched = ModelContext(container)
        #expect(try refetched.fetch(FetchDescriptor<SharedExpensePayment>()).first?.input.bankLink == nil)
    }

    @Test("Changes cannot erase a paid obligation and deleting a repayment restores the outstanding amount")
    func editsRespectPayments() async throws {
        let container = try ModelContainerFactory.make(mode: .local, inMemory: true).container
        let engine = SyncEngine(modelContainer: container)
        var expense = sharedFixture()
        try await engine.saveSharedExpense(expense)
        let payment = SharedPaymentInput(
            expenseID: expense.uuid, participantID: expense.participants[1].id, amountMinorUnits: 4_000
        )
        try await engine.addSharedPayment(payment)
        expense.payerID = expense.participants[1].id
        await #expect(throws: PersonalTrackingError.invalidParticipant) { try await engine.saveSharedExpense(expense) }
        try await engine.deleteSharedPayment(payment.uuid)
        try await engine.saveSharedExpense(expense)
        let row = try #require(container.mainContext.fetch(FetchDescriptor<SharedExpense>()).first)
        let balance = try SharedExpenseCalculator.balances(for: row.input, payments: [])
        #expect(balance.first?.outstandingMinorUnits == 4_000)
    }

    @Test("A contribution cannot be deleted if later withdrawals depend on it")
    func preventsNegativeFundEdits() async throws {
        let container = try ModelContainerFactory.make(mode: .local, inMemory: true).container
        let engine = SyncEngine(modelContainer: container)
        let now = Date.now
        let fund = SinkingFundInput(name: "Repairs", targetMinorUnits: 10_000)
        try await engine.saveSinkingFund(fund)
        let contribution = SinkingFundEntryInput(fundID: fund.uuid, amountMinorUnits: 5_000, date: now.addingTimeInterval(-1))
        let withdrawal = SinkingFundEntryInput(fundID: fund.uuid, amountMinorUnits: -2_000, kind: .withdrawal, date: now)
        try await engine.addSinkingFundEntry(contribution)
        try await engine.addSinkingFundEntry(withdrawal)
        await #expect(throws: PersonalTrackingError.insufficientFunds) {
            try await engine.deleteSinkingFundEntry(contribution.uuid)
        }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SinkingFundEntry>()) == 2)
        try await engine.deleteSinkingFundEntry(withdrawal.uuid)
        try await engine.deleteSinkingFundEntry(contribution.uuid)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SinkingFundEntry>()) == 0)
    }

    @Test("Archiving keeps history and prevents new activity until restored")
    func archivedRecords() async throws {
        let container = try ModelContainerFactory.make(mode: .local, inMemory: true).container
        let engine = SyncEngine(modelContainer: container)
        var expense = sharedFixture()
        expense.isArchived = true
        try await engine.saveSharedExpense(expense)
        let payment = SharedPaymentInput(expenseID: expense.uuid, participantID: expense.participants[1].id, amountMinorUnits: 1)
        await #expect(throws: PersonalTrackingError.missingRecord) { try await engine.addSharedPayment(payment) }
        var fund = SinkingFundInput(name: "Holiday", targetMinorUnits: 100, state: .archived)
        try await engine.saveSinkingFund(fund, openingMinorUnits: 20)
        let entry = SinkingFundEntryInput(fundID: fund.uuid, amountMinorUnits: 1)
        await #expect(throws: PersonalTrackingError.invalidAmount) { try await engine.addSinkingFundEntry(entry) }
        fund.state = .active
        try await engine.saveSinkingFund(fund)
        try await engine.addSinkingFundEntry(entry)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SinkingFundEntry>()) == 2)
    }

    @Test("Deleting a tracker removes its history and keeps account data")
    func deletion() async throws {
        let container = try ModelContainerFactory.make(mode: .local, inMemory: true).container
        let engine = SyncEngine(modelContainer: container)
        let expense = sharedFixture()
        try await engine.saveSharedExpense(expense)
        try await engine.addSharedPayment(SharedPaymentInput(
            expenseID: expense.uuid, participantID: expense.participants[1].id, amountMinorUnits: 1
        ))
        let fund = SinkingFundInput(name: "Repairs", targetMinorUnits: 100)
        try await engine.saveSinkingFund(fund, openingMinorUnits: 20)
        container.mainContext.insert(Account(bankAccountID: "A", name: "Checking"))
        try container.mainContext.save()
        try await engine.deleteSharedExpense(expense.uuid)
        try await engine.deleteSinkingFund(fund.uuid)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SharedExpense>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SharedExpensePayment>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SinkingFund>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SinkingFundEntry>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Account>()) == 1)
    }
}

private func sharedFixture() -> SharedExpenseInput {
    let people = [
        ExpenseParticipant(name: "You", shareMinorUnits: 4_000, isMe: true),
        ExpenseParticipant(name: "Alex", shareMinorUnits: 4_000),
        ExpenseParticipant(name: "Sam", shareMinorUnits: 4_000),
    ]
    return SharedExpenseInput(title: "Dinner", totalMinorUnits: 12_000, participants: people, payerID: people[0].id)
}
