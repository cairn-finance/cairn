import Foundation
import SwiftData

/// The user-editable fields of a manual transaction. Value type so the UI and
/// tests can describe an add or an edit without holding model references.
public struct ManualEntry: Sendable, Hashable {
    public var payee: String
    public var amountMinorUnits: Int64
    public var date: Date
    public var note: String?
    public var categoryID: PersistentIdentifier?
    public var tagIDs: [PersistentIdentifier]

    public init(
        payee: String,
        amountMinorUnits: Int64,
        date: Date,
        note: String? = nil,
        categoryID: PersistentIdentifier? = nil,
        tagIDs: [PersistentIdentifier] = []
    ) {
        self.payee = payee
        self.amountMinorUnits = amountMinorUnits
        self.date = date
        self.note = note
        self.categoryID = categoryID
        self.tagIDs = tagIDs
    }
}

/// Why a manual add, edit, or delete was refused. Manual editing never touches
/// bank-owned rows, so the refusals are all about identity and ownership.
public enum ManualEntryError: Error, Equatable, LocalizedError, Sendable {
    case accountNotFound
    case accountNotManual
    case transactionNotFound
    case emptyPayee
    case emptyAccountName

    public var errorDescription: String? {
        switch self {
        case .accountNotFound: "That account no longer exists."
        case .accountNotManual: "Only manual accounts can be edited."
        case .transactionNotFound: "That transaction no longer exists."
        case .emptyPayee: "Enter a description for the transaction."
        case .emptyAccountName: "Enter a name for the account."
        }
    }
}

// MARK: - Manual data editing

extension SyncEngine {
    /// Adds a user-entered transaction to a manual account. Identity is a
    /// generated `manual-` id so it can never collide with a bank row, and the
    /// row is marked imported like a CSV row.
    @discardableResult
    public func addManualTransaction(
        _ entry: ManualEntry,
        toAccountID accountID: PersistentIdentifier,
        now: Date = .now
    ) throws -> PersistentIdentifier {
        guard let account = live(Account.self, accountID) else {
            throw ManualEntryError.accountNotFound
        }
        try requireManual(account)

        let model = LedgerTransaction(
            bankTransactionID: "manual-\(UUID().uuidString.lowercased())",
            payeeDescription: "",
            amountMinorUnits: entry.amountMinorUnits
        )
        model.isPending = false
        model.currencyExponent = account.currency.exponent
        model.isImported = true
        model.accountIDIndex = account.bankAccountID
        model.account = account
        model.createdAt = now
        model.modifiedAt = now
        try apply(entry, to: model)
        modelContext.insert(model)

        try recomputeBalance(account, now: now)
        try modelContext.save()
        return model.persistentModelID
    }

    /// Replaces the user-editable fields of a manual transaction.
    public func updateManualTransaction(
        _ entry: ManualEntry,
        transactionID: PersistentIdentifier,
        now: Date = .now
    ) throws {
        guard let transaction = live(LedgerTransaction.self, transactionID) else {
            throw ManualEntryError.transactionNotFound
        }
        guard let account = transaction.account else {
            throw ManualEntryError.accountNotFound
        }
        try requireManual(account)

        try apply(entry, to: transaction)
        transaction.modifiedAt = now

        try recomputeBalance(account, now: now)
        try modelContext.save()
    }

    /// Deletes a manual transaction and recomputes the account balance.
    public func deleteManualTransaction(
        transactionID: PersistentIdentifier,
        now: Date = .now
    ) throws {
        guard let transaction = live(LedgerTransaction.self, transactionID) else {
            throw ManualEntryError.transactionNotFound
        }
        guard let account = transaction.account else {
            throw ManualEntryError.accountNotFound
        }
        try requireManual(account)

        modelContext.delete(transaction)
        try recomputeBalance(account, now: now)
        try modelContext.save()
    }

    /// Renames a manual account by setting its display override. The bank name
    /// (`name`) is left alone so the original label is never lost.
    public func renameManualAccount(
        accountID: PersistentIdentifier,
        name: String
    ) throws {
        guard let account = live(Account.self, accountID) else {
            throw ManualEntryError.accountNotFound
        }
        try requireManual(account)

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ManualEntryError.emptyAccountName }
        account.customDisplayName = trimmed
        try modelContext.save()
    }

    /// Deletes a manual account, cascading to its transactions.
    public func deleteManualAccount(
        accountID: PersistentIdentifier
    ) throws {
        guard let account = live(Account.self, accountID) else {
            throw ManualEntryError.accountNotFound
        }
        try requireManual(account)

        modelContext.delete(account)
        try modelContext.save()
    }

    // MARK: - Helpers

    /// Resolves a model by asking the store, not the context's cache, so a row
    /// deleted elsewhere is reported as missing instead of trapping on write.
    private func live<T: PersistentModel>(_: T.Type, _ id: PersistentIdentifier) -> T? {
        let descriptor = FetchDescriptor<T>(
            predicate: #Predicate { $0.persistentModelID == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func requireManual(_ account: Account) throws {
        guard account.isManual else { throw ManualEntryError.accountNotManual }
    }

    private func apply(_ entry: ManualEntry, to transaction: LedgerTransaction) throws {
        let payee = entry.payee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payee.isEmpty else { throw ManualEntryError.emptyPayee }

        transaction.payeeDescription = payee
        transaction.amountMinorUnits = entry.amountMinorUnits
        transaction.postedDate = entry.date
        transaction.normalizedMerchant = MerchantNormalizer.normalize(payee)

        let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        transaction.note = (note?.isEmpty ?? true) ? nil : note

        transaction.userCategory = entry.categoryID.flatMap { live(Category.self, $0) }
        transaction.tags = entry.tagIDs.compactMap { live(Tag.self, $0) }
    }

    /// Recomputes a manual account's balance from its opening balance and all of
    /// its transactions.
    private func recomputeBalance(_ account: Account, now: Date) throws {
        let accountBankID = account.bankAccountID
        let transactions = try modelContext.fetch(
            FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.accountIDIndex == accountBankID })
        )
        let sum = transactions
            .filter { !$0.isDeleted }
            .reduce(Int64(0)) { MinorUnits.addClamped($0, $1.amountMinorUnits) }
        account.balanceMinorUnits = MinorUnits.addClamped(account.startingBalanceMinorUnits, sum)
        account.balanceDate = now
    }
}
