import Foundation
import SwiftData
import Testing
@testable import CairnCore

/// Adding, editing, and deleting transactions in a manual account, plus
/// renaming and deleting the account itself.
@Suite("Manual entry")
@MainActor
struct ManualEntryTests {
    private func makeEngine() throws -> (container: ModelContainer, engine: SyncEngine) {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        return (result.container, SyncEngine(modelContainer: result.container))
    }

    @discardableResult
    private func insertManualAccount(
        in context: ModelContext,
        bankAccountID: String = "manual-1",
        startingBalance: Int64 = 100_000
    ) -> Account {
        let account = Account(bankAccountID: bankAccountID, name: "Cash", currency: .usd)
        account.sourceRaw = AccountSource.manual.rawValue
        account.accountTypeRaw = AccountType.cash.rawValue
        account.startingBalanceMinorUnits = startingBalance
        account.balanceMinorUnits = startingBalance
        context.insert(account)
        return account
    }

    @discardableResult
    private func insertSyncedTransaction(in context: ModelContext) -> LedgerTransaction {
        let account = Account(bankAccountID: "bank-1", name: "Checking", currency: .usd)
        account.sourceRaw = AccountSource.simpleFIN.rawValue
        context.insert(account)
        let transaction = LedgerTransaction(
            bankTransactionID: "BANK-1",
            payeeDescription: "Coffee",
            amountMinorUnits: -100
        )
        transaction.accountIDIndex = account.bankAccountID
        transaction.account = account
        context.insert(transaction)
        return transaction
    }

    @Test("Adding a transaction writes identity, merchant, and the account balance")
    func addTransaction() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let account = insertManualAccount(in: context)
        let category = Category(name: "Dining", symbolName: "fork.knife")
        let tag = Tag(name: "work", colorHex: "#FF3B30")
        context.insert(category)
        context.insert(tag)
        try context.save()

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = ManualEntry(
            payee: "  Blue Bottle Coffee #123  ",
            amountMinorUnits: -675,
            date: date,
            note: "  team coffee  ",
            categoryID: category.persistentModelID,
            tagIDs: [tag.persistentModelID]
        )
        let id = try await engine.addManualTransaction(entry, toAccountID: account.persistentModelID)

        let rows = try context.fetch(FetchDescriptor<LedgerTransaction>())
        let row = try #require(rows.first { $0.persistentModelID == id })
        #expect(row.bankTransactionID.hasPrefix("manual-"))
        #expect(row.payeeDescription == "Blue Bottle Coffee #123")
        #expect(row.amountMinorUnits == -675)
        #expect(row.postedDate == date)
        #expect(!row.isImported)
        #expect(!row.isPending)
        #expect(row.currencyExponent == 2)
        #expect(row.accountIDIndex == account.bankAccountID)
        #expect(row.normalizedMerchant == "Blue Bottle Coffee")
        #expect(row.note == "team coffee")
        #expect(row.userCategory?.name == "Dining")
        #expect(row.tags?.map(\.name) == ["work"])

        let refreshed = try #require(try context.fetch(FetchDescriptor<Account>()).first)
        #expect(refreshed.balanceMinorUnits == 99_325)
    }

    @Test("Editing updates every editable field and recomputes the balance")
    func editTransaction() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let account = insertManualAccount(in: context)
        let groceries = Category(name: "Groceries")
        context.insert(groceries)
        try context.save()

        let id = try await engine.addManualTransaction(
            ManualEntry(payee: "Old", amountMinorUnits: -1_000, date: Date(timeIntervalSince1970: 1_800_000_000)),
            toAccountID: account.persistentModelID
        )

        let newDate = Date(timeIntervalSince1970: 1_800_100_000)
        try await engine.updateManualTransaction(
            ManualEntry(
                payee: "New Payee",
                amountMinorUnits: -2_500,
                date: newDate,
                note: "updated",
                categoryID: groceries.persistentModelID,
                tagIDs: []
            ),
            transactionID: id
        )

        let rows = try context.fetch(FetchDescriptor<LedgerTransaction>())
        let row = try #require(rows.first { $0.persistentModelID == id })
        #expect(row.payeeDescription == "New Payee")
        #expect(row.amountMinorUnits == -2_500)
        #expect(row.postedDate == newDate)
        #expect(row.normalizedMerchant == "New Payee")
        #expect(row.note == "updated")
        #expect(row.userCategory?.name == "Groceries")

        let refreshed = try #require(try context.fetch(FetchDescriptor<Account>()).first)
        #expect(refreshed.balanceMinorUnits == 97_500)
    }

    @Test("Deleting a transaction removes it and restores the balance")
    func deleteTransaction() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let account = insertManualAccount(in: context)
        try context.save()

        let id = try await engine.addManualTransaction(
            ManualEntry(payee: "Coffee", amountMinorUnits: -500, date: Date()),
            toAccountID: account.persistentModelID
        )
        try await engine.deleteManualTransaction(transactionID: id)

        let count = try context.fetchCount(FetchDescriptor<LedgerTransaction>())
        #expect(count == 0)
        let refreshed = try #require(try context.fetch(FetchDescriptor<Account>()).first)
        #expect(refreshed.balanceMinorUnits == 100_000)
    }

    @Test("An empty payee is refused")
    func rejectsEmptyPayee() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let account = insertManualAccount(in: context)
        try context.save()

        do {
            _ = try await engine.addManualTransaction(
                ManualEntry(payee: "   ", amountMinorUnits: -100, date: Date()),
                toAccountID: account.persistentModelID
            )
            Issue.record("Expected an empty-payee error.")
        } catch let error as ManualEntryError {
            #expect(error == .emptyPayee)
        }
    }

    @Test("Synced rows stay read-only")
    func syncedRowsAreReadOnly() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let synced = insertSyncedTransaction(in: context)
        try context.save()

        let entry = ManualEntry(payee: "Edited", amountMinorUnits: -200, date: Date())
        let syncedAccountID = try #require(synced.account).persistentModelID

        do {
            _ = try await engine.addManualTransaction(entry, toAccountID: syncedAccountID)
            Issue.record("Expected an account-not-manual error.")
        } catch let error as ManualEntryError {
            #expect(error == .accountNotManual)
        }

        do {
            try await engine.updateManualTransaction(entry, transactionID: synced.persistentModelID)
            Issue.record("Expected an account-not-manual error.")
        } catch let error as ManualEntryError {
            #expect(error == .accountNotManual)
        }

        do {
            try await engine.deleteManualTransaction(transactionID: synced.persistentModelID)
            Issue.record("Expected an account-not-manual error.")
        } catch let error as ManualEntryError {
            #expect(error == .accountNotManual)
        }

        let count = try context.fetchCount(FetchDescriptor<LedgerTransaction>())
        #expect(count == 1)
    }

    @Test("Renaming sets the display override and deleting cascades")
    func renameAndDeleteAccount() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let account = insertManualAccount(in: context)
        try context.save()

        _ = try await engine.addManualTransaction(
            ManualEntry(payee: "Coffee", amountMinorUnits: -500, date: Date()),
            toAccountID: account.persistentModelID
        )
        try await engine.renameManualAccount(accountID: account.persistentModelID, name: "  Wallet Cash  ")

        let renamed = try #require(try context.fetch(FetchDescriptor<Account>()).first)
        #expect(renamed.customDisplayName == "Wallet Cash")
        #expect(renamed.displayName == "Wallet Cash")

        try await engine.deleteManualAccount(accountID: account.persistentModelID)

        #expect(try context.fetchCount(FetchDescriptor<Account>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()) == 0)
    }

    @Test("An empty account name is refused")
    func rejectsEmptyAccountName() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let account = insertManualAccount(in: context)
        try context.save()

        do {
            try await engine.renameManualAccount(accountID: account.persistentModelID, name: "  ")
            Issue.record("Expected an empty-name error.")
        } catch let error as ManualEntryError {
            #expect(error == .emptyAccountName)
        }
    }
}
