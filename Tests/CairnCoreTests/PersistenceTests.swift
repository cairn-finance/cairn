import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("Persistence")
@MainActor
struct PersistenceTests {
    @Test("Creates an in-memory local container and round-trips a model")
    func localContainerRoundTrip() throws {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        #expect(result.mode == .local)
        #expect(result.cloudFallbackReason == nil)

        let context = result.container.mainContext
        let institution = Institution(name: "Test Bank", credentialID: UUID())
        context.insert(institution)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        account.balanceMinorUnits = 12_345
        account.institution = institution
        context.insert(account)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Account>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.balanceMinorUnits == 12_345)
        #expect(fetched.first?.institution?.name == "Test Bank")
    }

    @Test("Currency round-trips through the account descriptor")
    func currencyDescriptor() {
        let account = Account(bankAccountID: "A1", name: "Miles", currency: Currency(
            code: "https://example.com/miles",
            exponent: 2,
            isCustom: true,
            customName: "Airline Miles",
            customAbbreviation: "mi"
        ))
        #expect(account.currency.isCustom)
        #expect(account.currency.displayLabel == "Airline Miles")
        #expect(account.currency.exponent == 2)
    }

    @Test("Every relationship has an inverse and is optional (CloudKit requirement)")
    func relationshipsAreCloudKitCompatible() {
        // CloudKit refuses to load a store when any relationship lacks an
        // inverse or is non-optional. Assert this structurally, without asking
        // CloudKit for a container (which traps when entitlements are absent).
        let schema = Schema(versionedSchema: CairnSchemaV1.self)
        var violations: [String] = []
        var inspected = 0
        for entity in schema.entities {
            for relationship in entity.relationships {
                inspected += 1
                if !relationship.isOptional {
                    violations.append("\(entity.name).\(relationship.name) is not optional")
                }
                if relationship.inverseName == nil {
                    violations.append("\(entity.name).\(relationship.name) has no inverse")
                }
            }
        }
        #expect(inspected >= 10, "expected to inspect the schema's relationships, found \(inspected)")
        #expect(violations.isEmpty, "CloudKit relationship violations: \(violations)")
    }

    @Test("Transaction amount keeps the account's custom currency")
    func transactionCustomCurrency() throws {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        let context = result.container.mainContext
        let currency = Currency(
            code: "https://example.com/miles",
            exponent: 2,
            isCustom: true,
            customName: "Airline Miles",
            customAbbreviation: "mi"
        )
        let account = Account(bankAccountID: "A1", name: "Miles", currency: currency)
        context.insert(account)
        let transaction = LedgerTransaction(bankTransactionID: "T1", payeeDescription: "Flight", amountMinorUnits: 12_345)
        transaction.account = account
        transaction.currencyExponent = 2
        context.insert(transaction)
        try context.save()

        #expect(transaction.amount.currency.isCustom)
        #expect(transaction.amount.currency.customName == "Airline Miles")
        #expect(transaction.amount.currency.displayLabel == "Airline Miles")
    }

    @Test("Seeding default categories is idempotent")
    func seedDefaultCategoriesIdempotent() async throws {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        let engine = SyncEngine(modelContainer: result.container)

        try await engine.seedDefaultCategoriesIfNeeded()
        let firstCount = try result.container.mainContext.fetchCount(FetchDescriptor<CairnCore.Category>())
        try await engine.seedDefaultCategoriesIfNeeded()
        let secondCount = try result.container.mainContext.fetchCount(FetchDescriptor<CairnCore.Category>())

        #expect(firstCount == 15)
        #expect(secondCount == firstCount)
    }

    @Test("Effective category prefers the user's choice")
    func effectiveCategory() throws {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        let context = result.container.mainContext

        let userCategory = Category(name: "Dining")
        let autoCategory = Category(name: "Groceries")
        context.insert(userCategory)
        context.insert(autoCategory)

        let transaction = LedgerTransaction(bankTransactionID: "T1", payeeDescription: "Cafe", amountMinorUnits: -500)
        transaction.autoCategory = autoCategory
        context.insert(transaction)

        #expect(transaction.effectiveCategory?.name == "Groceries")

        transaction.userCategory = userCategory
        #expect(transaction.effectiveCategory?.name == "Dining")
        #expect(transaction.isCategorizedByUser)
    }
}
