#if os(iOS)
import FinanceKit
import Foundation
import SwiftData

/// Reads eligible Apple Wallet data — Apple Card, Apple Cash, and Savings —
/// through FinanceKit and mirrors it into the local SwiftData store.
///
/// This path is completely independent of SimpleFIN: there is no credential, no
/// request budget, and no Cairn server. FinanceKit is device-local and
/// read-only. Amounts are stored as signed minor units, treating
/// `creditDebitIndicator == .debit` as money out for both assets and
/// liabilities, which matches how the rest of the app represents balances.
@ModelActor
public actor WalletSyncEngine {
    /// Prefixes keep Wallet rows from ever colliding with SimpleFIN ids in the
    /// shared `bankAccountID` / `bankTransactionID` namespace.
    public static let accountIDPrefix = "wallet-"
    public static let transactionIDPrefix = "wallet-"

    public struct WalletOutcome: Sendable, Equatable {
        public var accountsUpserted = 0
        public var transactionsInserted = 0
        public var transactionsUpdated = 0
        public var accountsRemoved = 0
        public init() {}
    }

    public enum WalletError: Error, LocalizedError {
        case unsupported
        case notAuthorized
        case restricted
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported:
                "Apple Wallet financial data isn’t available on this device."
            case .notAuthorized:
                "Cairn doesn’t have access to Wallet financial data. You can grant it in "
                    + "Settings › Privacy & Security › Financial Data."
            case .restricted:
                "Wallet data is temporarily unavailable. It may be locked or restricted by a device policy."
            case let .failed(message):
                message
            }
        }
    }

    /// Whether the Apple Wallet option should be offered.
    public nonisolated static var isSupported: Bool { WalletAvailability.isSupported }

    // MARK: - Authorization

    /// Shows the system account picker and reports whether access was granted.
    /// Re-running this once access exists returns the stored decision without
    /// prompting again.
    public func requestAuthorization() async throws -> Bool {
        guard Self.isSupported else { throw WalletError.unsupported }
        do {
            return try await FinanceStore.shared.requestAuthorization() == .authorized
        } catch let error as FinanceError {
            throw Self.walletError(error)
        }
    }

    /// Reads the current authorization without showing any UI.
    public func isAuthorized() async -> Bool {
        guard Self.isSupported else { return false }
        return (try? await FinanceStore.shared.authorizationStatus()) == .authorized
    }

    // MARK: - Sync

    /// Mirrors every account Wallet currently exposes, then drops any Wallet
    /// account it no longer reports.
    @discardableResult
    public func sync(now: Date = .now, calendar: Calendar = .current) async throws -> WalletOutcome {
        guard Self.isSupported else { throw WalletError.unsupported }
        let store = FinanceStore.shared

        let status: FinanceKit.AuthorizationStatus
        do {
            status = try await store.authorizationStatus()
        } catch let error as FinanceError {
            throw Self.walletError(error)
        }
        guard status == .authorized else { throw WalletError.notAuthorized }

        let walletAccounts: [FKAccount]
        do {
            walletAccounts = try await store.accounts(query: AccountQuery())
        } catch let error as FinanceError {
            throw Self.walletError(error)
        }

        var outcome = WalletOutcome()
        var seen = Set<String>()
        for walletAccount in walletAccounts {
            seen.insert(Self.accountKey(walletAccount.id))

            let balances = try? await latestBalances(for: walletAccount.id, store: store)
            await cairnLog(
                .info,
                "Wallet balance for \(walletAccount.displayName): "
                    + "booked=\(balances?.booked != nil) available=\(balances?.available != nil)"
            )
            let account = try upsertAccount(
                walletAccount,
                booked: balances?.booked,
                available: balances?.available,
                now: now,
                outcome: &outcome
            )
            let transactions = (try? await transactions(for: walletAccount.id, store: store)) ?? []
            try reconcile(transactions, into: account, now: now, outcome: &outcome)
            try recordSnapshot(for: account, now: now, calendar: calendar)
        }

        try removeMissingAccounts(seen: seen, outcome: &outcome)
        try modelContext.save()
        await cairnLog(
            .info,
            "Wallet sync: accounts=\(outcome.accountsUpserted) inserted=\(outcome.transactionsInserted) "
                + "updated=\(outcome.transactionsUpdated) removed=\(outcome.accountsRemoved)"
        )
        return outcome
    }

    // MARK: - Accounts

    private func upsertAccount(
        _ walletAccount: FKAccount,
        booked: FKBalance?,
        available: FKBalance?,
        now: Date,
        outcome: inout WalletOutcome
    ) throws -> Account {
        let key = Self.accountKey(walletAccount.id)
        var descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.bankAccountID == key })
        descriptor.fetchLimit = 1

        let account: Account
        if let existing = try modelContext.fetch(descriptor).first {
            account = existing
        } else {
            account = Account(
                bankAccountID: key,
                name: walletAccount.displayName,
                currency: Self.currency(for: walletAccount.currencyCode)
            )
            modelContext.insert(account)
        }

        let type = Self.accountType(for: walletAccount)
        account.sourceRaw = AccountSource.financeKit.rawValue
        account.name = walletAccount.displayName
        account.apply(currency: Self.currency(for: walletAccount.currencyCode))
        account.accountTypeRaw = type.rawValue
        account.institution = nil
        account.lastSyncedAt = now

        // For a credit card the booked balance is what is owed and the available
        // balance is the remaining credit — they are not interchangeable. For a
        // deposit account the available balance is the current one, including
        // pending activity.
        let balance = type.isLiability ? (booked ?? available) : (available ?? booked)
        if let balance {
            account.balanceMinorUnits = Self.signedMinorUnits(balance.amount, indicator: balance.creditDebitIndicator)
            account.balanceDate = balance.asOfDate
        }
        if let available {
            // Available credit/spending power is always a positive capacity, even
            // for a liability account.
            account.availableBalanceMinorUnits = abs(Self.signedMinorUnits(available.amount, indicator: available.creditDebitIndicator))
            account.hasAvailableBalance = true
        } else {
            account.availableBalanceMinorUnits = account.balanceMinorUnits
            account.hasAvailableBalance = false
        }
        outcome.accountsUpserted += 1
        return account
    }

    private func removeMissingAccounts(seen: Set<String>, outcome: inout WalletOutcome) throws {
        let source = AccountSource.financeKit.rawValue
        let accounts = try modelContext.fetch(
            FetchDescriptor<Account>(predicate: #Predicate { $0.sourceRaw == source })
        )
        for account in accounts where !seen.contains(account.bankAccountID) {
            modelContext.delete(account)
            outcome.accountsRemoved += 1
        }
    }

    // MARK: - Balances

    private func latestBalances(
        for accountID: UUID,
        store: FinanceStore
    ) async throws -> (booked: FKBalance?, available: FKBalance?) {
        let query = AccountBalanceQuery(
            sortDescriptors: [SortDescriptor(\FinanceKit.AccountBalance.id)],
            predicate: #Predicate<FinanceKit.AccountBalance> { $0.accountID == accountID },
            limit: nil,
            offset: nil
        )
        let balances = try await store.accountBalances(query: query)

        var booked: FKBalance?
        var available: FKBalance?
        for balance in balances {
            switch balance.currentBalance {
            case let .available(value):
                available = Self.later(available, value)
            case let .booked(value):
                booked = Self.later(booked, value)
            case let .availableAndBooked(availableValue, bookedValue):
                available = Self.later(available, availableValue)
                booked = Self.later(booked, bookedValue)
            @unknown default:
                continue
            }
        }
        return (booked, available)
    }

    private static func later(_ current: FKBalance?, _ candidate: FKBalance) -> FKBalance {
        guard let current else { return candidate }
        return candidate.asOfDate >= current.asOfDate ? candidate : current
    }

    // MARK: - Transactions

    private func transactions(for accountID: UUID, store: FinanceStore) async throws -> [FKTransaction] {
        let query = TransactionQuery(
            sortDescriptors: [SortDescriptor(\FKTransaction.transactionDate, order: .reverse)],
            predicate: #Predicate<FKTransaction> { $0.accountID == accountID },
            limit: nil,
            offset: nil
        )
        return try await store.transactions(query: query)
    }

    private func reconcile(
        _ incoming: [FKTransaction],
        into account: Account,
        now: Date,
        outcome: inout WalletOutcome
    ) throws {
        let accountKey = account.bankAccountID
        var descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.accountIDIndex == accountKey }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.account]
        let existing = try modelContext.fetch(descriptor)
        var byID = Dictionary(existing.map { ($0.bankTransactionID, $0) }, uniquingKeysWith: { first, _ in first })

        for txn in incoming where txn.status != .rejected {
            let key = Self.transactionKey(txn.id)
            let description = Self.description(for: txn)
            let amount = Self.signedMinorUnits(txn.transactionAmount, indicator: txn.creditDebitIndicator)
            let posted = txn.postedDate ?? txn.transactionDate
            let isPending = txn.status != .booked

            if let model = byID[key] {
                let changed = model.payeeDescription != description
                    || model.amountMinorUnits != amount
                    || model.postedDate != posted
                    || model.transactedAt != txn.transactionDate
                    || model.isPending != isPending
                model.payeeDescription = description
                model.amountMinorUnits = amount
                model.postedDate = posted
                model.transactedAt = txn.transactionDate
                model.isPending = isPending
                model.normalizedMerchant = MerchantNormalizer.normalize(description)
                model.currencyExponent = account.currency.exponent
                model.accountIDIndex = account.bankAccountID
                model.account = account
                if changed {
                    model.modifiedAt = now
                    outcome.transactionsUpdated += 1
                }
            } else {
                let model = LedgerTransaction(
                    bankTransactionID: key,
                    payeeDescription: description,
                    amountMinorUnits: amount
                )
                model.postedDate = posted
                model.transactedAt = txn.transactionDate
                model.isPending = isPending
                model.normalizedMerchant = MerchantNormalizer.normalize(description)
                model.currencyExponent = account.currency.exponent
                model.accountIDIndex = account.bankAccountID
                model.account = account
                model.createdAt = now
                model.modifiedAt = now
                modelContext.insert(model)
                byID[key] = model
                outcome.transactionsInserted += 1
            }
        }
    }

    private func recordSnapshot(for account: Account, now: Date, calendar: Calendar) throws {
        let day = calendar.startOfDay(for: now)
        let accountKey = account.bankAccountID
        let descriptor = FetchDescriptor<BalanceSnapshot>(
            predicate: #Predicate { $0.account?.bankAccountID == accountKey }
        )
        let snapshots = try modelContext.fetch(descriptor)

        if let today = snapshots.first(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
            today.balanceMinorUnits = account.balanceMinorUnits
        } else {
            let snapshot = BalanceSnapshot(day: day, balanceMinorUnits: account.balanceMinorUnits)
            snapshot.account = account
            modelContext.insert(snapshot)
        }
    }

    // MARK: - Mapping

    private static func accountKey(_ id: UUID) -> String { accountIDPrefix + id.uuidString }
    private static func transactionKey(_ id: UUID) -> String { transactionIDPrefix + id.uuidString }

    private static func description(for txn: FKTransaction) -> String {
        if let merchant = txn.merchantName, !merchant.isEmpty { return merchant }
        if !txn.transactionDescription.isEmpty { return txn.transactionDescription }
        return txn.originalTransactionDescription
    }

    private static func accountType(for account: FKAccount) -> AccountType {
        switch account {
        case .liability:
            return .credit
        case .asset:
            let name = account.displayName.lowercased()
            if name.contains("saving") { return .savings }
            if name.contains("cash") { return .cash }
            return .other
        @unknown default:
            return .other
        }
    }

    private static func currency(for code: String) -> Currency {
        Currency(code: code.uppercased(), exponent: Currency.defaultExponent(forISOCode: code))
    }

    private static func signedMinorUnits(
        _ amount: FinanceKit.CurrencyAmount,
        indicator: FinanceKit.CreditDebitIndicator
    ) -> Int64 {
        let exponent = Currency.defaultExponent(forISOCode: amount.currencyCode)
        let magnitude = abs(MinorUnits.parse("\(amount.amount)", exponent: exponent) ?? 0)
        return indicator == .debit ? -magnitude : magnitude
    }

    private static func walletError(_ error: FinanceError) -> WalletError {
        switch error {
        case .dataRestricted:
            return .restricted
        case .historyTokenInvalid:
            return .failed("Wallet’s change history expired. Cairn will rebuild it on the next sync.")
        case .unknown:
            return .failed("Wallet returned an unexpected error.")
        @unknown default:
            return .failed("Wallet returned an unexpected error.")
        }
    }
}

/// Local aliases so FinanceKit's `Account` never collides with Cairn's model.
private typealias FKAccount = FinanceKit.Account
private typealias FKTransaction = FinanceKit.Transaction
private typealias FKBalance = FinanceKit.Balance
#endif
