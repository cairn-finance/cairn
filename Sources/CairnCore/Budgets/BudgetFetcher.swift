import Foundation
import SwiftData

public struct BudgetAccountScope: Sendable, Hashable {
    public let bankAccountID: String

    public init(bankAccountID: String) {
        self.bankAccountID = bankAccountID
    }
}

/// Fetches current-month ledger inputs away from SwiftUI's main actor.
@ModelActor
public actor BudgetFetcher {
    public func budgetTransactions(
        scopes: [BudgetAccountScope],
        from start: Date,
        to end: Date
    ) throws -> [BudgetTransaction] {
        var result: [BudgetTransaction] = []
        for scope in scopes {
            let accountID = scope.bankAccountID
            let descriptor = FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.accountIDIndex == accountID }
            )
            let rows = try modelContext.fetch(descriptor)
            for transaction in rows {
                let date = transaction.effectiveDate
                guard date >= start && date < end else { continue }
                let category = transaction.effectiveCategory
                result.append(
                    BudgetTransaction(
                        date: date,
                        amountMinorUnits: transaction.amountMinorUnits,
                        categoryUUID: category?.uuid,
                        categoryName: category?.name,
                        isTransfer: transaction.countsAsTransfer,
                        isIgnored: transaction.isIgnored,
                        isPending: transaction.isPending
                    )
                )
            }
        }
        return result
    }
}
