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
        to end: Date,
        timeZone: TimeZone = .current
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

        var plansByTransaction: [BudgetSmoothingTransactionKey: BudgetSmoothingPlan] = [:]
        for plan in try modelContext.fetch(FetchDescriptor<BudgetSmoothingPlan>()) {
            let key = BudgetSmoothingTransactionKey(
                accountIDIndex: plan.accountIDIndex,
                bankTransactionID: plan.bankTransactionID
            )
            if let current = plansByTransaction[key] {
                if plan.modifiedAt > current.modifiedAt
                    || (plan.modifiedAt == current.modifiedAt && plan.uuid.uuidString < current.uuid.uuidString) {
                    plansByTransaction[key] = plan
                }
            } else {
                plansByTransaction[key] = plan
            }
        }

        var result: [BudgetTransaction] = []
        for transaction in fetchedRows {
            let date = transaction.effectiveDate
            let linkedCategory = transaction.settlementID.flatMap { expenseCategories[$0] }
            let category = linkedCategory ?? {
                let effective = transaction.effectiveCategory
                return SettlementBudgetCategory(uuid: effective?.uuid, name: effective?.name)
            }()

            var usedSmoothingPlan = false
            let key = BudgetSmoothingTransactionKey(
                accountIDIndex: transaction.accountIDIndex,
                bankTransactionID: transaction.bankTransactionID
            )
            if transaction.isEligibleForBudgetExpenseSmoothing,
               let plan = plansByTransaction[key],
               (BudgetExpenseSmoothingCalculator.minimumMonths...BudgetExpenseSmoothingCalculator.maximumMonths)
                .contains(plan.durationMonths),
               BudgetCalculator.startOfMonth(plan.startMonthKey, timeZone: timeZone) != nil {
                usedSmoothingPlan = true
                for index in 0..<plan.durationMonths {
                    guard let monthKey = BudgetCalculator.shiftMonth(
                        plan.startMonthKey,
                        by: index,
                        timeZone: timeZone
                    ) else { break }
                    guard let allocationStart = BudgetCalculator.startOfMonth(monthKey, timeZone: timeZone),
                          allocationStart >= start,
                          allocationStart < end,
                          let amount = BudgetExpenseSmoothingCalculator.allocationAmount(
                            totalMinorUnits: MinorUnits.absClamped(transaction.amountMinorUnits),
                            monthIndex: index,
                            monthCount: plan.durationMonths
                          ) else { continue }
                    let allocation = BudgetSmoothingAllocation(
                        planID: plan.uuid,
                        name: plan.name,
                        payeeDescription: transaction.payeeDescription,
                        sourceTransactionID: "\(transaction.accountIDIndex)/\(transaction.bankTransactionID)",
                        monthKey: monthKey,
                        installmentNumber: index + 1,
                        installmentCount: plan.durationMonths,
                        amountMinorUnits: amount,
                        totalMinorUnits: MinorUnits.absClamped(transaction.amountMinorUnits)
                    )
                    result.append(
                        BudgetTransaction(
                            date: allocationStart,
                            amountMinorUnits: -amount,
                            categoryUUID: category.uuid,
                            categoryName: category.name,
                            isTransfer: transaction.countsAsTransfer,
                            isIgnored: transaction.isIgnored,
                            isPending: transaction.isPending,
                            smoothingAllocation: allocation
                        )
                    )
                }
            }
            if usedSmoothingPlan { continue }
            guard date >= start && date < end else { continue }
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
