import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("Schema migration")
@MainActor
struct SchemaMigrationTests {
    @Test("A V1 disk store migrates to V2 without losing spending data")
    func v1StoreMigratesToV2() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cairn-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Cairn.store")
        let categoryID = UUID()
        let postedDate = Date(timeIntervalSince1970: 1_700_000_000)

        // Close the V1 container before opening the same SQLite file as V2.
        try createV1Store(at: storeURL, categoryID: categoryID, postedDate: postedDate)

        let schema = Schema(versionedSchema: CairnSchemaV2.self)
        let configuration = ModelConfiguration(
            "Cairn", schema: schema, url: storeURL, cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema, migrationPlan: CairnMigrationPlan.self, configurations: configuration
        )
        let context = container.mainContext

        let institutions = try context.fetch(FetchDescriptor<Institution>())
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let categories = try context.fetch(FetchDescriptor<CairnCore.Category>())
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        let tags = try context.fetch(FetchDescriptor<CairnCore.Tag>())
        let rules = try context.fetch(FetchDescriptor<CategorizationRule>())
        let settings = try context.fetch(FetchDescriptor<AppSettings>())
        let budgets = try context.fetch(FetchDescriptor<CategoryBudget>())

        #expect(institutions.count == 1)
        #expect(accounts.count == 1)
        #expect(categories.count == 1)
        #expect(transactions.count == 1)
        #expect(tags.count == 1)
        #expect(rules.count == 1)
        #expect(settings.count == 1)
        #expect(budgets.isEmpty)
        #expect(accounts.first?.institution?.name == "Migration Test Bank")
        #expect(accounts.first?.balanceMinorUnits == 123_456)
        #expect(categories.first?.uuid == categoryID)
        #expect(transactions.first?.bankTransactionID == "migration-transaction")
        #expect(transactions.first?.amountMinorUnits == -4_321)
        #expect(transactions.first?.postedDate == postedDate)
        #expect(transactions.first?.account?.bankAccountID == "migration-account")
        #expect(transactions.first?.userCategory?.uuid == categoryID)
        #expect(transactions.first?.tags?.first?.name == "Migration Test Tag")
        #expect(rules.first?.assignedCategory?.uuid == categoryID)
        #expect(settings.first?.onboardingComplete == true)

        let budget = CategoryBudget(
            categoryUUID: categoryID, monthKey: "2026-09", amountMinorUnits: 50_000
        )
        context.insert(budget)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<CategoryBudget>()).first?.amountMinorUnits == 50_000)
    }

    private func createV1Store(at url: URL, categoryID: UUID, postedDate: Date) throws {
        let schema = Schema(versionedSchema: CairnSchemaV1.self)
        let configuration = ModelConfiguration(
            "Cairn", schema: schema, url: url, cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = container.mainContext

        let institution = CairnSchemaV1.Institution(name: "Migration Test Bank")
        let account = CairnSchemaV1.Account(bankAccountID: "migration-account", name: "Checking")
        account.balanceMinorUnits = 123_456
        account.institution = institution
        let category = CairnSchemaV1.Category(name: "Dining", uuid: categoryID)
        let tag = CairnSchemaV1.Tag(name: "Migration Test Tag")
        let transaction = CairnSchemaV1.LedgerTransaction(
            bankTransactionID: "migration-transaction",
            payeeDescription: "Migration Test Cafe",
            amountMinorUnits: -4_321
        )
        transaction.postedDate = postedDate
        transaction.account = account
        transaction.userCategory = category
        transaction.tags = [tag]
        let rule = CairnSchemaV1.CategorizationRule(
            name: "Migration Test Rule", pattern: "cafe", assignedCategory: category
        )
        let settings = CairnSchemaV1.AppSettings()
        settings.onboardingComplete = true

        context.insert(institution)
        context.insert(account)
        context.insert(category)
        context.insert(tag)
        context.insert(transaction)
        context.insert(rule)
        context.insert(settings)
        try context.save()
    }
}
