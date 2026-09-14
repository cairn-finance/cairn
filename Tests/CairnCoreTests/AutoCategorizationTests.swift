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
}
