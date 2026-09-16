import Foundation
import SwiftData

extension LedgerTransaction {
    /// Stable identity used to match a detected series back to its rows. The
    /// bank id is only unique within an account, so the account's bank id is
    /// part of the key.
    public var recurringIdentifier: String {
        let accountKey = accountIDIndex.isEmpty ? (account?.bankAccountID ?? "") : accountIDIndex
        return "\(accountKey)|\(bankTransactionID)"
    }
}

extension RecurringDetector {
    /// Maps persisted transactions to the pure detector's input.
    ///
    /// The effective category is read for display only; detection itself keys on
    /// the merchant, amount, date, and account, so a later recategorization
    /// never changes which series exist.
    public static func detect(
        transactions: [LedgerTransaction],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [RecurringSeries] {
        let inputs = transactions.compactMap { transaction -> RecurringInput? in
            // A hidden account is out of the picture everywhere else, so its
            // charges should not surface as recurring either.
            guard let account = transaction.account, !account.isHidden else { return nil }
            let merchant = transaction.normalizedMerchant.isEmpty
                ? transaction.payeeDescription
                : transaction.normalizedMerchant
            let trimmed = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            return RecurringInput(
                id: transaction.recurringIdentifier,
                merchantKey: trimmed.lowercased(),
                displayName: trimmed,
                amountMinorUnits: transaction.amountMinorUnits,
                date: transaction.effectiveDate,
                accountID: transaction.accountIDIndex.isEmpty
                    ? account.bankAccountID
                    : transaction.accountIDIndex,
                accountName: account.displayName,
                currency: account.currency,
                categoryName: transaction.effectiveCategory?.name,
                categoryColorHex: transaction.effectiveCategory?.colorHex,
                categorySymbolName: transaction.effectiveCategory?.symbolName,
                isTransfer: transaction.countsAsTransfer,
                isIgnored: transaction.isIgnored,
                isPending: transaction.isPending
            )
        }
        return detect(inputs, now: now, calendar: calendar)
    }
}
