import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("Delete all data")
@MainActor
struct DeleteAllDataTests {
    @Test("Delete All Data removes every model, including holdings")
    func removesEverything() async throws {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        let container = result.container
        let context = container.mainContext

        let institution = Institution(bankConnectionID: "CON-1", name: "Bank", sfinURL: "https://example.com")
        context.insert(institution)

        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        account.institution = institution
        context.insert(account)

        let transaction = LedgerTransaction(
            bankTransactionID: "T1",
            payeeDescription: "Coffee",
            amountMinorUnits: -500
        )
        transaction.account = account
        transaction.accountIDIndex = "A1"
        context.insert(transaction)

        let holding = Holding(holdingID: "H1", name: "Index Fund", currency: .usd)
        holding.account = account
        context.insert(holding)

        let tag = CairnCore.Tag(name: "Tax", colorHex: "#34C759")
        context.insert(tag)
        transaction.tags = [tag]

        let category = CairnCore.Category(name: "Dining", symbolName: "fork.knife", colorHex: "#FF9F0A", sortOrder: 0)
        context.insert(category)
        let rule = CategorizationRule(
            name: "Coffee",
            field: .payee,
            matchKind: .contains,
            pattern: "coffee",
            assignedCategory: category
        )
        context.insert(rule)

        let snapshot = BalanceSnapshot(day: .now, balanceMinorUnits: 1_000)
        snapshot.account = account
        context.insert(snapshot)
        context.insert(AppSettings())
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        try await engine.deleteAllData()

        #expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Holding>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BalanceSnapshot>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CategorizationRule>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CairnCore.Tag>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CairnCore.Category>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Account>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Institution>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<AppSettings>()) == 0)
        _ = container
    }
}
