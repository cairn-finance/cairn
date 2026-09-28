import Foundation
import SwiftData

public struct BudgetAccountScope: Sendable, Hashable {
    public let bankAccountID: String

    public init(bankAccountID: String) {
        self.bankAccountID = bankAccountID
    }
}

private struct SettlementBudgetCategory {
    let uuid: UUID?
    let name: String?
}

/// Fetches current-month ledger inputs away from SwiftUI's main actor.
@ModelActor
public actor BudgetFetcher {
    public func budgetTransactions(
        scopes: [BudgetAccountScope],
        from start: Date,
        to end: Date
    ) throws -> [BudgetTransaction] {
        var fetchedRows: [LedgerTransaction] = []
        for scope in scopes {
            let accountID = scope.bankAccountID
            let descriptor = FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.accountIDIndex == accountID }
            )
            let rows = try modelContext.fetch(descriptor)
            fetchedRows.append(contentsOf: rows)
        }

        var expenseCategories: [UUID: SettlementBudgetCategory] = [:]
        for transaction in fetchedRows {
            guard transaction.settlementRole == .expense,
                  let settlementID = transaction.settlementID else { continue }
            let category = transaction.effectiveCategory
            expenseCategories[settlementID] = SettlementBudgetCategory(
                uuid: category?.uuid,
                name: category?.name
            )
        }

        var result: [BudgetTransaction] = []
        for transaction in fetchedRows {
            let date = transaction.effectiveDate
            guard date >= start && date < end else { continue }
            let linkedCategory = transaction.settlementID.flatMap { expenseCategories[$0] }
            let category = linkedCategory ?? {
                let effective = transaction.effectiveCategory
                return SettlementBudgetCategory(uuid: effective?.uuid, name: effective?.name)
            }()
            result.append(
                BudgetTransaction(
                    date: date,
                    amountMinorUnits: transaction.amountMinorUnits,
                    categoryUUID: category.uuid,
                    categoryName: category.name,
                    isTransfer: transaction.countsAsTransfer,
                    isIgnored: transaction.isIgnored,
                    isPending: transaction.isPending
                )
            )
        }
        return result
    }
}
