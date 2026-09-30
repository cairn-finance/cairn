import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("Investment transaction classification")
@MainActor
struct InvestmentTransactionClassificationTests {
    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainerFactory.make(mode: .local, inMemory: true).container
        let context = container.mainContext
        let settings = AppSettings()
        settings.categorizationVersion = SyncEngine.currentCategorizationVersion
        context.insert(settings)
        return (container, context)
    }

    private func investmentAccount(in context: ModelContext) -> Account {
        let account = Account(bankAccountID: "BROKER", name: "Sample Investment Account", currency: .usd)
        account.accountTypeRaw = AccountType.investment.rawValue
        context.insert(account)
        return account
    }

    private func transaction(
        _ id: String, description: String, amount: Int64,
        account: Account, context: ModelContext
    ) -> LedgerTransaction {
        let transaction = LedgerTransaction(
            bankTransactionID: id, payeeDescription: description, amountMinorUnits: amount
        )
        transaction.account = account
        transaction.accountIDIndex = account.bankAccountID
        transaction.normalizedMerchant = MerchantNormalizer.normalize(description)
        transaction.postedDate = Date(timeIntervalSince1970: 1_788_307_200)
        context.insert(transaction)
        return transaction
    }

    private func fetch(_ id: String, in context: ModelContext) throws -> LedgerTransaction {
        try #require(context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.bankTransactionID == id }
        )).first)
    }

    @Test("Share purchases repair model and merchant-memory shopping labels without a version reset")
    func repairsAutomaticShopping() async throws {
        let (container, context) = try makeContext()
        let account = investmentAccount(in: context)
        let shopping = Category(name: "Shopping")
        context.insert(shopping)
        for (index, source) in ["appleIntelligence", "memory", "similarMerchant"].enumerated() {
            let row = transaction(
                "BUY\(index)", description: "buy 0.125 shares of Sample Technology", amount: -2_500,
                account: account, context: context
            )
            row.autoCategory = shopping
            row.autoCategorySource = source
            row.autoCategorizeAttemptedAt = .now
        }
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        let now = Date(timeIntervalSince1970: 1_788_393_600)
        _ = try await engine.recategorize(now: now)
        for index in 0..<3 {
            let row = try fetch("BUY\(index)", in: context)
            #expect(row.countsAsTransfer)
            #expect(row.autoCategory == nil)
            #expect(row.autoCategorizeAttemptedAt == nil)
            #expect(row.amountMinorUnits == -2_500)
        }
        #expect(try await engine.uncategorizedCount() == 0)

        // Reopening or syncing must not relearn the old Shopping guess.
        _ = try await engine.recategorize(now: now.addingTimeInterval(60))
        #expect(try fetch("BUY0", in: context).countsAsTransfer)
        #expect(try fetch("BUY0", in: context).modifiedAt == now)
    }

    @Test("A direct model batch resolves share purchases as movement without any model calls")
    func batchSkipsTrades() async throws {
        let (container, context) = try makeContext()
        let account = investmentAccount(in: context)
        context.insert(Category(name: "Shopping"))
        _ = transaction(
            "BUY", description: "buy 0.25 shares of Sample Index Fund", amount: -5_000,
            account: account, context: context
        )
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        let outcome = try await engine.appleIntelligenceCategorizeBatch()
        #expect(outcome.modelCalls == 0)
        #expect(outcome.remaining == 0)
        #expect(try fetch("BUY", in: context).countsAsTransfer)
    }

    @Test("Broker trade wording requires investment context and does not hide card purchases or fees")
    func tradeHintBoundaries() {
        for description in [
            "buy 0.125 shares of Sample Technology", "SELL 2 SHARES OF SAMPLE FUND",
            "You bought Sample ETF", "BOT 10 SAMPLE", "SLD 5 SAMPLE",
            "PURCHASE 10 SHARES SAMPLE COMMON STOCK", "REINVEST Sample Index Fund",
        ] {
            #expect(TransactionHints.isInvestmentTrade(description: description, accountType: .investment))
            #expect(!TransactionHints.isInvestmentTrade(description: description, accountType: .checking))
        }
        for description in [
            "BEST BUY #123", "POS PURCHASE BEST BUY", "DEBIT CARD PURCHASE SAMPLE STORE",
            "PURCHASE AUTHORIZED ON 09/01", "PURCHASE PHARMACY", "Sample Fund Dividend",
            "BUY ORDER SERVICE FEE", "Monthly maintenance fee", "Interest payment",
        ] {
            #expect(!TransactionHints.isInvestmentTrade(description: description, accountType: .investment))
        }
    }

    @Test("Reporting excludes trades while retaining investment fees, dividends, and retail spending")
    func reportingExcludesTrades() async throws {
        let (container, context) = try makeContext()
        let account = investmentAccount(in: context)
        let shopping = Category(name: "Shopping")
        context.insert(shopping)
        context.insert(Category(name: "Income"))
        context.insert(Category(name: "Fees"))
        let timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let start = try #require(BudgetCalculator.startOfMonth("2026-09", timeZone: timeZone))
        for (id, description, amount) in [
            ("BUY", "buy 0.25 shares of Sample Fund", Int64(-5_000)),
            ("SELL", "sell 0.5 shares of Sample Fund", 7_000),
            ("FEE", "Investment account service fee", -500),
            ("DIV", "Sample Fund dividend", 1_000),
            ("RETAIL", "POS PURCHASE BEST BUY #123", -2_000),
        ] {
            let row = transaction(id, description: description, amount: amount, account: account, context: context)
            row.postedDate = start.addingTimeInterval(86_400)
            if id == "RETAIL" { row.userCategory = shopping }
        }
        try context.save()
        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.recategorize()
        #expect(try fetch("BUY", in: context).countsAsTransfer)
        #expect(try fetch("SELL", in: context).countsAsTransfer)
        #expect(try fetch("FEE", in: context).effectiveCategory?.name == "Fees")
        #expect(try fetch("DIV", in: context).effectiveCategory?.name == "Income")
        #expect(try fetch("RETAIL", in: context).effectiveCategory?.name == "Shopping")

        let insights = InsightsFetcher(modelContainer: container)
        let inputs = await insights.insightTransactions(
            scopes: [InsightAccountScope(bankAccountID: "BROKER", displayName: "Sample Investment Account")],
            earliest: start
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let summary = InsightsCalculator.snapshot(transactions: inputs, month: start, calendar: calendar)
        #expect(summary.current.spendingMinorUnits == 2_500)
        #expect(summary.current.incomeMinorUnits == 1_000)

        let budgets = BudgetFetcher(modelContainer: container)
        let budgetInputs = try await budgets.budgetTransactions(
            scopes: [BudgetAccountScope(bankAccountID: "BROKER")],
            from: start, to: start.addingTimeInterval(31 * 86_400), timeZone: timeZone
        )
        let budget = BudgetCalculator.snapshot(
            transactions: budgetInputs, categories: [], settings: [],
            monthKey: "2026-09", currency: .usd, timeZone: timeZone
        )
        #expect(budget.spentMinorUnits == 2_500)
        let rows = try context.fetch(FetchDescriptor<LedgerTransaction>()).map { $0.rowValue() }
        let sections = TransactionSectionBuilder.months(from: rows, calendar: calendar)
        #expect(sections.first?.spentMinorUnits == 2_500)
    }

    @Test("Manual categories, transfer choices, ignored rows, and explicit rules retain precedence")
    func preservesUserChoices() async throws {
        let (container, context) = try makeContext()
        let account = investmentAccount(in: context)
        let shopping = Category(name: "Shopping")
        context.insert(shopping)
        for id in ["MANUAL", "FLAG", "IGNORED", "RULE"] {
            let row = transaction(
                id, description: "buy 1 shares of Sample \(id)", amount: -10_000,
                account: account, context: context
            )
            row.autoCategory = shopping
            row.autoCategorySource = "appleIntelligence"
            if id == "MANUAL" { row.userCategory = shopping }
            if id == "FLAG" { row.isTransferUserSet = true }
            if id == "IGNORED" { row.isIgnored = true }
        }
        context.insert(CategorizationRule(name: "Explicit category", pattern: "Sample RULE", assignedCategory: shopping))
        try context.save()
        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.recategorize()
        for id in ["MANUAL", "FLAG", "IGNORED", "RULE"] {
            let row = try fetch(id, in: context)
            #expect(!row.countsAsTransfer)
            #expect(row.effectiveCategory?.name == "Shopping")
        }
        #expect(try fetch("MANUAL", in: context).userCategory?.uuid == shopping.uuid)
        #expect(try fetch("FLAG", in: context).isTransferUserSet)
        #expect(try fetch("IGNORED", in: context).isIgnored)
    }

    @Test("A retail merchant correction cannot propagate Shopping back onto a recognized trade")
    func merchantPropagationPreservesTrades() async throws {
        let (container, context) = try makeContext()
        let account = investmentAccount(in: context)
        let shopping = Category(name: "Shopping")
        context.insert(shopping)
        let purchase = transaction(
            "RETAIL", description: "Sample Store", amount: -2_000, account: account, context: context
        )
        purchase.userCategory = shopping
        purchase.normalizedMerchant = "sample"
        let trade = transaction(
            "BUY", description: "buy 0.25 shares of Sample", amount: -5_000, account: account, context: context
        )
        trade.normalizedMerchant = "sample"
        try context.save()
        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.recategorize()
        #expect(try await engine.propagateUserCategory(transactionID: purchase.persistentModelID) == 0)
        #expect(try fetch("BUY", in: context).countsAsTransfer)
        #expect(try fetch("BUY", in: context).autoCategory == nil)
    }
}
