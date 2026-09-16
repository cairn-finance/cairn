import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("Rule application")
@MainActor
struct RuleApplicationTests {
    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        return (result.container, result.container.mainContext)
    }

    private func date(_ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day)) ?? .distantPast
    }

    @discardableResult
    private func addTransaction(
        _ context: ModelContext,
        account: Account,
        id: String,
        description: String,
        amountMinorUnits: Int64 = -1_500,
        month: Int = 1
    ) -> LedgerTransaction {
        let transaction = LedgerTransaction(
            bankTransactionID: id,
            payeeDescription: description,
            amountMinorUnits: amountMinorUnits
        )
        transaction.account = account
        transaction.accountIDIndex = account.bankAccountID
        transaction.postedDate = date(month, 5)
        transaction.normalizedMerchant = MerchantNormalizer.normalize(description)
        context.insert(transaction)
        return transaction
    }

    @Test("A rule categorizes existing transactions when applied")
    func ruleCategorizesExistingRows() async throws {
        let (container, context) = try makeContext()
        let dining = Category(name: "Dining", symbolName: "fork.knife", colorHex: "#FF9F0A", sortOrder: 0)
        context.insert(dining)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)
        addTransaction(context, account: account, id: "T1", description: "Blue Bottle Coffee", month: 1)
        addTransaction(context, account: account, id: "T2", description: "BLUE BOTTLE COFFEE #12", month: 2)

        let rule = CategorizationRule(
            name: "Coffee",
            field: .payee,
            matchKind: .contains,
            pattern: "blue bottle",
            assignedCategory: dining
        )
        context.insert(rule)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        let outcome = try await engine.applyRules()

        let refreshed = try context.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(refreshed.allSatisfy { $0.autoCategory?.name == "Dining" })
        #expect(refreshed.allSatisfy { $0.autoCategorySource == "rule" })
        #expect(outcome.categorized >= 2)
        _ = container
    }

    @Test("Removing a rule clears the category it had assigned")
    func removingRuleClearsItsCategory() async throws {
        let (container, context) = try makeContext()
        let dining = Category(name: "Dining", symbolName: "fork.knife", colorHex: "#FF9F0A", sortOrder: 0)
        context.insert(dining)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)
        addTransaction(context, account: account, id: "T1", description: "Blue Bottle Coffee", month: 1)

        let rule = CategorizationRule(
            name: "Coffee",
            field: .payee,
            matchKind: .contains,
            pattern: "blue bottle",
            assignedCategory: dining
        )
        context.insert(rule)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.applyRules()

        let categorized = try context.fetch(FetchDescriptor<LedgerTransaction>()).first
        #expect(categorized?.autoCategory?.name == "Dining")

        context.delete(rule)
        try context.save()
        _ = try await engine.applyRules()

        let cleared = try context.fetch(FetchDescriptor<LedgerTransaction>()).first
        #expect(cleared?.autoCategory == nil)
        #expect(cleared?.autoCategorySource == nil)
        _ = container
    }

    @Test("A rule never overrides a category the person set")
    func userChoiceIsNeverOverridden() async throws {
        let (container, context) = try makeContext()
        let groceries = Category(name: "Groceries", symbolName: "cart.fill", colorHex: "#30B0C7", sortOrder: 0)
        let dining = Category(name: "Dining", symbolName: "fork.knife", colorHex: "#FF9F0A", sortOrder: 1)
        context.insert(groceries)
        context.insert(dining)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)

        let transaction = addTransaction(context, account: account, id: "T1", description: "Blue Bottle Coffee", month: 1)
        transaction.userCategory = groceries

        let rule = CategorizationRule(
            name: "Coffee",
            field: .payee,
            matchKind: .contains,
            pattern: "blue bottle",
            assignedCategory: dining
        )
        context.insert(rule)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.applyRules()

        let refreshed = try context.fetch(FetchDescriptor<LedgerTransaction>()).first
        #expect(refreshed?.userCategory?.name == "Groceries")
        #expect(refreshed?.autoCategory == nil)
        _ = container
    }

    @Test("A rule outranks merchant memory")
    func ruleBeatsMerchantMemory() async throws {
        let (container, context) = try makeContext()
        let dining = Category(name: "Dining", symbolName: "fork.knife", colorHex: "#FF9F0A", sortOrder: 0)
        let entertainment = Category(name: "Entertainment", symbolName: "play.circle.fill", colorHex: "#BF5AF2", sortOrder: 1)
        context.insert(dining)
        context.insert(entertainment)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)

        // The person categorized one row; the next should still prefer the rule.
        let known = addTransaction(context, account: account, id: "T1", description: "ACME STORE", month: 1)
        known.userCategory = dining
        addTransaction(context, account: account, id: "T2", description: "ACME STORE", month: 2)

        let rule = CategorizationRule(
            name: "ACME",
            field: .payee,
            matchKind: .contains,
            pattern: "acme",
            assignedCategory: entertainment
        )
        context.insert(rule)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.applyRules()

        let rows = try context.fetch(FetchDescriptor<LedgerTransaction>())
        let automatic = try #require(rows.first { $0.bankTransactionID == "T2" })
        #expect(automatic.autoCategory?.name == "Entertainment")
        #expect(automatic.autoCategorySource == "rule")
        _ = container
    }

    @Test("A disabled rule is not applied")
    func disabledRuleDoesNothing() async throws {
        let (container, context) = try makeContext()
        let dining = Category(name: "Dining", symbolName: "fork.knife", colorHex: "#FF9F0A", sortOrder: 0)
        context.insert(dining)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)
        addTransaction(context, account: account, id: "T1", description: "Blue Bottle Coffee", month: 1)

        let rule = CategorizationRule(
            name: "Coffee",
            field: .payee,
            matchKind: .contains,
            pattern: "blue bottle",
            assignedCategory: dining
        )
        rule.isEnabled = false
        context.insert(rule)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.applyRules()

        let refreshed = try context.fetch(FetchDescriptor<LedgerTransaction>()).first
        #expect(refreshed?.autoCategory == nil)
        _ = container
    }

    @Test("The higher-priority rule wins")
    func priorityWins() async throws {
        let (container, context) = try makeContext()
        let dining = Category(name: "Dining", symbolName: "fork.knife", colorHex: "#FF9F0A", sortOrder: 0)
        let entertainment = Category(name: "Entertainment", symbolName: "play.circle.fill", colorHex: "#BF5AF2", sortOrder: 1)
        context.insert(dining)
        context.insert(entertainment)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)
        addTransaction(context, account: account, id: "T1", description: "Blue Bottle Coffee", month: 1)

        let low = CategorizationRule(
            name: "Low", field: .payee, matchKind: .contains,
            pattern: "coffee", assignedCategory: dining, priority: 1
        )
        let high = CategorizationRule(
            name: "High", field: .payee, matchKind: .contains,
            pattern: "coffee", assignedCategory: entertainment, priority: 10
        )
        context.insert(low)
        context.insert(high)
        try context.save()

        let engine = SyncEngine(modelContainer: container)
        _ = try await engine.applyRules()

        let refreshed = try context.fetch(FetchDescriptor<LedgerTransaction>()).first
        #expect(refreshed?.autoCategory?.name == "Entertainment")
        _ = container
    }
}

@Suite("Tag persistence")
@MainActor
struct TagPersistenceTests {
    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        return (result.container, result.container.mainContext)
    }

    @Test("Tags attach to a transaction and detach when removed")
    func assigningAndRemovingTags() throws {
        let (container, context) = try makeContext()
        let tag = CairnCore.Tag(name: "Reimbursable", colorHex: "#34C759")
        context.insert(tag)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)
        let transaction = LedgerTransaction(
            bankTransactionID: "T1",
            payeeDescription: "Coffee",
            amountMinorUnits: -500
        )
        transaction.account = account
        transaction.accountIDIndex = "A1"
        context.insert(transaction)
        try context.save()

        transaction.tags = [tag]
        try context.save()

        var refreshed = try context.fetch(FetchDescriptor<LedgerTransaction>()).first
        #expect(refreshed?.tags?.count == 1)
        #expect(refreshed?.tags?.first?.name == "Reimbursable")

        refreshed?.tags = []
        try context.save()

        refreshed = try context.fetch(FetchDescriptor<LedgerTransaction>()).first
        #expect((refreshed?.tags ?? []).isEmpty)
        _ = container
    }

    @Test("Deleting a tag leaves the transaction but removes the tag")
    func deletingTagDetachesIt() throws {
        let (container, context) = try makeContext()
        let tag = CairnCore.Tag(name: "Reimbursable", colorHex: "#34C759")
        context.insert(tag)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)
        let transaction = LedgerTransaction(
            bankTransactionID: "T1",
            payeeDescription: "Coffee",
            amountMinorUnits: -500
        )
        transaction.account = account
        transaction.accountIDIndex = "A1"
        context.insert(transaction)
        try context.save()

        transaction.tags = [tag]
        try context.save()
        #expect(tag.transactions?.count == 1)

        context.delete(tag)
        try context.save()

        let refreshed = try context.fetch(FetchDescriptor<LedgerTransaction>()).first
        #expect(refreshed != nil)
        #expect((refreshed?.tags ?? []).isEmpty)
        #expect((try context.fetch(FetchDescriptor<CairnCore.Tag>())).isEmpty)
        _ = container
    }
}
