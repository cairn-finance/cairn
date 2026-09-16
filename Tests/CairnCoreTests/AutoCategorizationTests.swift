import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("Automatic categorization")
@MainActor
struct AutoCategorizationTests {
    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        return (result.container, result.container.mainContext)
    }

    @Test("Rules and merchant memory categorize without a model")
    func memoryAssigns() async throws {
        let (container, context) = try makeContext()
        let groceries = Category(name: "Groceries", symbolName: "cart.fill", colorHex: "#30B0C7", sortOrder: 0)
        let dining = Category(name: "Dining", symbolName: "fork.knife", colorHex: "#FF9F0A", sortOrder: 1)
        context.insert(groceries)
        context.insert(dining)

        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)

        // A transaction the person already categorized teaches merchant memory.
        let known = LedgerTransaction(bankTransactionID: "T1", payeeDescription: "Whole Foods", amountMinorUnits: -8_000)
        known.account = account
        known.accountIDIndex = "A1"
        known.normalizedMerchant = MerchantNormalizer.normalize("Whole Foods")
        known.userCategory = groceries
        context.insert(known)

        // A new, uncategorized transaction from the same merchant.
        let unknown = LedgerTransaction(
            bankTransactionID: "T2",
            payeeDescription: "WHOLE FOODS MARKET #123",
            amountMinorUnits: -7_500
        )
        unknown.account = account
        unknown.accountIDIndex = "A1"
        unknown.normalizedMerchant = MerchantNormalizer.normalize("Whole Foods")
        context.insert(unknown)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        #expect(try await engine.uncategorizedCount() == 1)

        let outcome = try await engine.recategorize()
        #expect(outcome.categorized == 1)

        let refreshed = try context.fetch(
            FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == "T2" })
        ).first
        #expect(refreshed?.autoCategory?.name == "Groceries")
        #expect(refreshed?.autoCategorySource == "memory")
        #expect(try await engine.uncategorizedCount() == 0)
    }

    @Test("Transfers, ignored, and pending transactions aren't counted")
    func countExclusions() async throws {
        let (container, context) = try makeContext()
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)

        func make(_ id: String, transfer: Bool = false, ignored: Bool = false, pending: Bool = false) -> LedgerTransaction {
            let transaction = LedgerTransaction(bankTransactionID: id, payeeDescription: id, amountMinorUnits: -100)
            transaction.account = account
            transaction.accountIDIndex = "A1"
            transaction.isTransfer = transfer
            transaction.isIgnored = ignored
            transaction.isPending = pending
            return transaction
        }

        context.insert(make("plain"))
        context.insert(make("transfer", transfer: true))
        context.insert(make("ignored", ignored: true))
        context.insert(make("pending", pending: true))
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        #expect(try await engine.uncategorizedCount() == 1)
    }

    @Test("Overdraft transfers and Zelle are transfers, never fees")
    func moneyMovementIsTransfer() async throws {
        let (container, context) = try makeContext()
        context.insert(Category(name: "Fees", symbolName: "percent", colorHex: "#A2845E", sortOrder: 0))
        context.insert(Category(
            name: "Transfers",
            symbolName: "arrow.left.arrow.right",
            colorHex: "#32ADE6",
            sortOrder: 1,
            isSystem: true
        ))
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)

        func make(_ id: String, _ description: String) -> LedgerTransaction {
            let transaction = LedgerTransaction(
                bankTransactionID: id,
                payeeDescription: description,
                amountMinorUnits: -2_500
            )
            transaction.account = account
            transaction.accountIDIndex = "A1"
            transaction.normalizedMerchant = MerchantNormalizer.normalize(description)
            context.insert(transaction)
            return transaction
        }

        _ = make("T1", "Overdraft to checking")
        _ = make("T2", "Zelle payment to Jordan")
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.recategorize()

        func refetch(_ id: String) throws -> LedgerTransaction {
            try #require(
                try context.fetch(
                    FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == id })
                ).first
            )
        }

        #expect(try refetch("T1").isTransfer)
        #expect(try refetch("T2").isTransfer)
        #expect(try refetch("T1").autoCategory == nil)
        #expect(try refetch("T2").autoCategory == nil)
        #expect(try await engine.uncategorizedCount() == 0)
    }

    @Test("A real charge is recognized as a fee")
    func explicitFeeIsCategorized() async throws {
        let (container, context) = try makeContext()
        context.insert(Category(name: "Fees", symbolName: "percent", colorHex: "#A2845E", sortOrder: 0))
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)

        let fee = LedgerTransaction(
            bankTransactionID: "T1",
            payeeDescription: "Overdraft fee",
            amountMinorUnits: -3_500
        )
        fee.account = account
        fee.accountIDIndex = "A1"
        fee.normalizedMerchant = MerchantNormalizer.normalize("Overdraft fee")
        context.insert(fee)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.recategorize()

        let refreshed = try #require(
            try context.fetch(
                FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == "T1" })
            ).first
        )
        #expect(refreshed.autoCategory?.name == "Fees")
        #expect(refreshed.autoCategorySource == "heuristic")
        #expect(!refreshed.isTransfer)
    }

    @Test("A correction propagates to the same merchant's other rows")
    func correctionPropagates() async throws {
        let (container, context) = try makeContext()
        let rent = Category(name: "Housing", symbolName: "house.fill", colorHex: "#8E8E93", sortOrder: 0)
        context.insert(rent)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)

        func make(_ id: String) -> LedgerTransaction {
            let transaction = LedgerTransaction(
                bankTransactionID: id,
                payeeDescription: "Zelle payment to Jordan",
                amountMinorUnits: -120_000
            )
            transaction.account = account
            transaction.accountIDIndex = "A1"
            transaction.normalizedMerchant = MerchantNormalizer.normalize("Zelle payment to Jordan")
            context.insert(transaction)
            return transaction
        }

        let corrected = make("T1")
        let other = make("T2")
        corrected.userCategory = rent
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        let changed = try await engine.propagateUserCategory(transactionID: corrected.persistentModelID)
        #expect(changed == 1)

        let refreshed = try #require(
            try context.fetch(
                FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == "T2" })
            ).first
        )
        #expect(refreshed.autoCategory?.name == "Housing")
        #expect(refreshed.autoCategorySource == "memory")
        #expect(!refreshed.isTransfer)
    }

    @Test("A payroll credit is categorized as Income, never Fees")
    func payrollBecomesIncome() async throws {
        let (container, context) = try makeContext()
        context.insert(Category(name: "Income", symbolName: "arrow.down.circle.fill", colorHex: "#34C759", sortOrder: 0))
        context.insert(Category(name: "Fees", symbolName: "percent", colorHex: "#A2845E", sortOrder: 1))
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)

        let payroll = LedgerTransaction(
            bankTransactionID: "T1",
            payeeDescription: "ACME INC PAYROLL PPD ID: 0000000000",
            amountMinorUnits: 200_000
        )
        payroll.account = account
        payroll.accountIDIndex = "A1"
        payroll.normalizedMerchant = MerchantNormalizer.normalize(payroll.payeeDescription)
        context.insert(payroll)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.recategorize()

        let refreshed = try #require(
            try context.fetch(
                FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == "T1" })
            ).first
        )
        #expect(refreshed.autoCategory?.name == "Income")
        #expect(refreshed.autoCategorySource == "heuristic")
    }

    @Test("A stale model-assigned fee is cleared and re-evaluated")
    func staleModelCategorySelfHeals() async throws {
        let (container, context) = try makeContext()
        let fees = Category(name: "Fees", symbolName: "percent", colorHex: "#A2845E", sortOrder: 0)
        context.insert(fees)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)

        // A model guess from an earlier build that could still pick Fees for a
        // row with no explicit charge word.
        let stale = LedgerTransaction(
            bankTransactionID: "T1",
            payeeDescription: "ACH: CHASE",
            amountMinorUnits: -10_000
        )
        stale.account = account
        stale.accountIDIndex = "A1"
        stale.normalizedMerchant = MerchantNormalizer.normalize("ACH: CHASE")
        stale.autoCategory = fees
        stale.autoCategorySource = "appleIntelligence"
        stale.autoCategorizeAttemptedAt = .now
        context.insert(stale)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.recategorize()

        let refreshed = try #require(
            try context.fetch(
                FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == "T1" })
            ).first
        )
        #expect(refreshed.autoCategory == nil)
        #expect(refreshed.autoCategorizeAttemptedAt == nil)
    }

    @Test("A stranded model attempt is retried, not left uncategorized forever")
    func stalledModelAttemptIsRequeued() async throws {
        let (container, context) = try makeContext()
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)

        // A row an earlier pass looked at but never produced a category for.
        let stranded = LedgerTransaction(
            bankTransactionID: "T1",
            payeeDescription: "AT&T",
            amountMinorUnits: -6_533
        )
        stranded.account = account
        stranded.accountIDIndex = "A1"
        stranded.normalizedMerchant = MerchantNormalizer.normalize("AT&T")
        stranded.autoCategorizeAttemptedAt = .now
        context.insert(stranded)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        #expect(try await engine.uncategorizedCount() == 1)

        _ = try await engine.recategorize()

        let refreshed = try #require(
            try context.fetch(
                FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == "T1" })
            ).first
        )
        #expect(refreshed.autoCategorizeAttemptedAt == nil)
        #expect(try await engine.categorizationCounts().pendingModel == 1)
    }

    @Test("A credit mislabeled as spending by an older model pass is re-evaluated")
    func staleCreditReevaluated() async throws {
        let (container, context) = try makeContext()
        let shopping = Category(name: "Shopping", symbolName: "bag.fill", colorHex: "#FF375F", sortOrder: 0)
        context.insert(shopping)
        let account = Account(bankAccountID: "A1", name: "Savings", currency: .usd)
        context.insert(account)

        // A model guess from before the classifier knew the amount direction.
        let stale = LedgerTransaction(
            bankTransactionID: "T1",
            payeeDescription: "ACH: ACME INDUSTRIES PAYROLL",
            amountMinorUnits: 200_000
        )
        stale.account = account
        stale.accountIDIndex = "A1"
        stale.normalizedMerchant = MerchantNormalizer.normalize("ACH: ACME INDUSTRIES PAYROLL")
        stale.autoCategory = shopping
        stale.autoCategorySource = "appleIntelligence"
        stale.autoCategorizeAttemptedAt = .now
        context.insert(stale)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.recategorize()

        let refreshed = try #require(
            try context.fetch(
                FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == "T1" })
            ).first
        )
        #expect(refreshed.autoCategory == nil)
        #expect(refreshed.autoCategorizeAttemptedAt == nil)
        #expect(try await engine.categorizationCounts().pendingModel == 1)
    }

    @Test("An old model label on a debit is overwritten by the current rules")
    func staleDebitLabelOverwritten() async throws {
        let (container, context) = try makeContext()
        let shopping = Category(name: "Shopping", symbolName: "bag.fill", colorHex: "#FF375F", sortOrder: 0)
        context.insert(shopping)
        let account = Account(bankAccountID: "A1", name: "Sample Brokerage", currency: .usd)
        context.insert(account)

        // A brokerage reinvestment the old model had called Shopping.
        let stale = LedgerTransaction(
            bankTransactionID: "T1",
            payeeDescription: "REINVESTMENT SAMPLE INDEX FUND (Cash)",
            amountMinorUnits: -338
        )
        stale.account = account
        stale.accountIDIndex = "A1"
        stale.normalizedMerchant = MerchantNormalizer.normalize("REINVESTMENT SAMPLE INDEX FUND")
        stale.autoCategory = shopping
        stale.autoCategorySource = "appleIntelligence"
        stale.autoCategorizeAttemptedAt = .now
        context.insert(stale)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.recategorize()

        let refreshed = try #require(
            try context.fetch(
                FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == "T1" })
            ).first
        )
        #expect(refreshed.isTransfer)
        #expect(refreshed.autoCategory == nil)
        #expect(refreshed.countsAsTransfer)
        #expect(try await engine.uncategorizedCount() == 0)
    }

    @Test("Card and loan payments carry their own category, not a generic transfer")
    func paymentCategories() async throws {
        let (container, context) = try makeContext()
        context.insert(Category(
            name: "Credit Card Payments", symbolName: "creditcard.fill", colorHex: "#0A84FF", sortOrder: 0
        ))
        context.insert(Category(
            name: "Loan Payments", symbolName: "building.columns.fill", colorHex: "#5AC8FA", sortOrder: 1
        ))
        let account = Account(bankAccountID: "A1", name: "Everyday Checking", currency: .usd)
        context.insert(account)

        func make(_ id: String, _ description: String) -> LedgerTransaction {
            let transaction = LedgerTransaction(
                bankTransactionID: id,
                payeeDescription: description,
                amountMinorUnits: -10_000
            )
            transaction.account = account
            transaction.accountIDIndex = "A1"
            transaction.normalizedMerchant = MerchantNormalizer.normalize(description)
            context.insert(transaction)
            return transaction
        }

        _ = make("T1", "Payment Thank You-Mobile")
        _ = make("T2", "LOAN PAYMENT")
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.recategorize()

        func refetch(_ id: String) throws -> LedgerTransaction {
            try #require(
                try context.fetch(
                    FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == id })
                ).first
            )
        }

        let card = try refetch("T1")
        #expect(card.isTransfer)
        #expect(card.countsAsTransfer)
        #expect(card.autoCategory?.name == "Credit Card Payments")

        let loan = try refetch("T2")
        #expect(loan.isTransfer)
        #expect(loan.autoCategory?.name == "Loan Payments")

        // Both are money movement, so neither is a spending row awaiting review.
        #expect(try await engine.uncategorizedCount() == 0)
    }

    @Test("New built-in categories are added once for existing installs")
    func paymentCategorySeeding() async throws {
        let (container, context) = try makeContext()
        let engine = SyncEngine(modelContainer: container)

        // An install that seeded the first generation before these existed.
        let settings = AppSettings()
        settings.hasSeededDefaultCategories = true
        settings.categorySeedVersion = 0
        context.insert(settings)
        try context.save()

        try await engine.seedDefaultCategoriesIfNeeded()
        var names = try context.fetch(FetchDescriptor<CairnCore.Category>()).map(\.name)
        #expect(names.contains("Credit Card Payments"))
        #expect(names.contains("Loan Payments"))
        // Only the additions are seeded; the first generation stays untouched.
        #expect(!names.contains("Groceries"))

        // Running again does not duplicate anything.
        try await engine.seedDefaultCategoriesIfNeeded()
        names = try context.fetch(FetchDescriptor<CairnCore.Category>()).map(\.name)
        #expect(names.filter { $0 == "Loan Payments" }.count == 1)

        // A category the person deletes is not resurrected.
        let loan = try #require(
            try context.fetch(FetchDescriptor<CairnCore.Category>()).first { $0.name == "Loan Payments" }
        )
        context.delete(loan)
        try context.save()
        try await engine.seedDefaultCategoriesIfNeeded()
        names = try context.fetch(FetchDescriptor<CairnCore.Category>()).map(\.name)
        #expect(!names.contains("Loan Payments"))
    }

    @Test("Duplicate categories are collapsed and references repointed")
    func duplicateCategoriesCollapse() async throws {
        let (container, context) = try makeContext()
        let original = Category(name: "Groceries", symbolName: "cart.fill", colorHex: "#30B0C7", sortOrder: 0)
        let duplicate = Category(name: "Groceries", symbolName: "cart.fill", colorHex: "#30B0C7", sortOrder: 0)
        context.insert(original)
        context.insert(duplicate)

        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)
        let transaction = LedgerTransaction(
            bankTransactionID: "T1",
            payeeDescription: "Whole Foods",
            amountMinorUnits: -8_000
        )
        transaction.account = account
        transaction.accountIDIndex = "A1"
        transaction.userCategory = duplicate
        context.insert(transaction)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        let removed = try await engine.deduplicateCategories()
        #expect(removed == 1)

        let remaining = try context.fetch(FetchDescriptor<CairnCore.Category>())
            .filter { $0.name == "Groceries" }
        #expect(remaining.count == 1)
        let refreshed = try #require(
            try context.fetch(
                FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == "T1" })
            ).first
        )
        #expect(refreshed.userCategory?.uuid == remaining.first?.uuid)
    }

    @Test("A merchant the model placed teaches memory, so a repeat sync skips the model")
    func modelDecisionBecomesMemory() async throws {
        let (container, context) = try makeContext()
        let groceries = Category(name: "Groceries", symbolName: "cart.fill", colorHex: "#30B0C7", sortOrder: 0)
        context.insert(groceries)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)

        // A previous run already used the on-device model for this merchant.
        let placed = LedgerTransaction(
            bankTransactionID: "T1",
            payeeDescription: "WHOLE FOODS MARKET #123",
            amountMinorUnits: -8_000
        )
        placed.account = account
        placed.accountIDIndex = "A1"
        placed.normalizedMerchant = MerchantNormalizer.normalize("Whole Foods")
        placed.autoCategory = groceries
        placed.autoCategorySource = "appleIntelligence"
        placed.autoCategorizeAttemptedAt = .now
        context.insert(placed)

        // A new row from the same merchant.
        let fresh = LedgerTransaction(
            bankTransactionID: "T2",
            payeeDescription: "WHOLE FOODS MARKET #999",
            amountMinorUnits: -4_200
        )
        fresh.account = account
        fresh.accountIDIndex = "A1"
        fresh.normalizedMerchant = MerchantNormalizer.normalize("Whole Foods")
        context.insert(fresh)

        // This install already ran the current categorization generation, so the
        // one-time re-evaluation does not clear the model's decision.
        let settings = AppSettings()
        settings.categorizationVersion = SyncEngine.currentCategorizationVersion
        context.insert(settings)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.recategorize()

        let refreshed = try #require(
            try context.fetch(
                FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == "T2" })
            ).first
        )
        #expect(refreshed.autoCategory?.name == "Groceries")
        #expect(refreshed.autoCategorySource == "memory")

        // The model's own row keeps its label; memory agreeing is not a downgrade.
        let original = try #require(
            try context.fetch(
                FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == "T1" })
            ).first
        )
        #expect(original.autoCategorySource == "appleIntelligence")
    }

    @Test("A categorization version bump re-examines learned decisions once")
    func versionBumpReexaminesLearnedDecisions() async throws {
        let (container, context) = try makeContext()
        let groceries = Category(name: "Groceries", symbolName: "cart.fill", colorHex: "#30B0C7", sortOrder: 0)
        context.insert(groceries)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)

        // A learned decision from an older build.
        let learned = LedgerTransaction(
            bankTransactionID: "T1",
            payeeDescription: "BLUE BOTTLE COFFEE",
            amountMinorUnits: -1_850
        )
        learned.account = account
        learned.accountIDIndex = "A1"
        learned.normalizedMerchant = MerchantNormalizer.normalize("BLUE BOTTLE COFFEE")
        learned.autoCategory = groceries
        learned.autoCategorySource = "memory"
        context.insert(learned)

        let settings = AppSettings()
        settings.categorizationVersion = SyncEngine.currentCategorizationVersion - 1
        context.insert(settings)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.recategorize()

        let refreshed = try #require(
            try context.fetch(
                FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == "T1" })
            ).first
        )
        #expect(refreshed.autoCategory == nil)
        #expect(try await engine.categorizationCounts().pendingModel == 1)
    }

    @Test("The on-device model pauses on heat, low power, and optionally battery")
    func powerPolicy() {
        func evaluate(
            thermal: ProcessInfo.ThermalState = .nominal,
            lowPower: Bool = false,
            onPower: Bool = true,
            requiresPower: Bool = false
        ) -> CategorizationPower.Decision {
            CategorizationPower.evaluate(
                thermalState: thermal,
                isLowPowerMode: lowPower,
                isOnExternalPower: onPower,
                requiresExternalPower: requiresPower
            )
        }

        #expect(evaluate() == .proceed)
        #expect(evaluate(thermal: .serious) == .pauseThermal)
        #expect(evaluate(thermal: .critical) == .pauseThermal)
        #expect(evaluate(lowPower: true) == .pauseLowPower)
        #expect(evaluate(onPower: false, requiresPower: true) == .pauseBattery)
        // A foreground pass is allowed on battery; only the bulk pass waits.
        #expect(evaluate(onPower: false, requiresPower: false) == .proceed)
    }

    @Test("Merchant names are trimmed to protect the model's context window")
    func merchantTrimming() {
        #expect(
            AppleIntelligenceCategorizer.trimmedMerchant("  WHOLE   FOODS \n MARKET ")
                == "WHOLE FOODS MARKET"
        )
        let long = String(repeating: "A", count: 500)
        #expect(AppleIntelligenceCategorizer.trimmedMerchant(long).count == 90)

        // Adaptive batch size must stay inside safe bounds on every device, even
        // when the context size is unknown.
        let size = AppleIntelligenceCategorizer.recommendedMerchantBatchSize
        #expect(size >= 4 && size <= 12)
    }

    @Test("A transfer to a financial institution becomes money movement")
    func financialCounterpartyTransfer() async throws {
        let (container, context) = try makeContext()
        context.insert(Category(name: "Income", symbolName: "arrow.down.circle.fill", colorHex: "#34C759", sortOrder: 0))
        let account = Account(bankAccountID: "A1", name: "Everyday Checking", currency: .usd)
        context.insert(account)

        func make(_ id: String, _ description: String, _ amount: Int64) -> LedgerTransaction {
            let transaction = LedgerTransaction(
                bankTransactionID: id,
                payeeDescription: description,
                amountMinorUnits: amount
            )
            transaction.account = account
            transaction.accountIDIndex = "A1"
            transaction.normalizedMerchant = MerchantNormalizer.normalize(description)
            context.insert(transaction)
            return transaction
        }

        _ = make("T1", "ACH: CAPITAL ONE", -405_949)
        _ = make("T2", "ACH: AMERICAN EXPRESS", -10_000)
        // A dividend from a brokerage is income, not a transfer, even though the
        // counterparty is a brokerage.
        _ = make("T3", "VANGUARD DIVIDEND", 4_200)
        _ = make("T4", "ACME INC PAYROLL PPD ID: 0000000000", 200_000)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.recategorize()

        func refetch(_ id: String) throws -> LedgerTransaction {
            try #require(
                try context.fetch(
                    FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == id })
                ).first
            )
        }

        #expect(try refetch("T1").isTransfer)
        #expect(try refetch("T1").autoCategory == nil)
        #expect(try refetch("T2").isTransfer)
        let dividend = try refetch("T3")
        #expect(dividend.autoCategory?.name == "Income")
        #expect(!dividend.isTransfer)
        #expect(try refetch("T4").autoCategory?.name == "Income")
    }
}
