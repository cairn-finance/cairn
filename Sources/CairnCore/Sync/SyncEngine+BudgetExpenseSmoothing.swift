import Foundation
import SwiftData

public extension SyncEngine {
    func saveBudgetExpenseSmoothing(
        _ input: BudgetExpenseSmoothingInput,
        now: Date = .now
    ) throws {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= BudgetExpenseSmoothingCalculator.maximumNameLength else {
            throw BudgetExpenseSmoothingError.invalidName
        }
        guard (BudgetExpenseSmoothingCalculator.minimumMonths...BudgetExpenseSmoothingCalculator.maximumMonths)
            .contains(input.durationMonths) else {
            throw BudgetExpenseSmoothingError.invalidDuration
        }
        guard let timeZone = TimeZone(identifier: input.timeZoneIdentifier),
              BudgetCalculator.startOfMonth(input.startMonthKey, timeZone: timeZone) != nil else {
            throw BudgetExpenseSmoothingError.invalidMonth
        }

        let accountIDIndex = input.accountIDIndex
        let bankTransactionID = input.bankTransactionID
        let descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate {
                $0.accountIDIndex == accountIDIndex && $0.bankTransactionID == bankTransactionID
            }
        )
        guard let transaction = try modelContext.fetch(descriptor).first else {
            throw BudgetExpenseSmoothingError.transactionNotFound
        }
        guard transaction.isEligibleForBudgetExpenseSmoothing else {
            throw BudgetExpenseSmoothingError.transactionNotEligible
        }
        let purchaseMonthKey = BudgetCalculator.monthKey(for: transaction.effectiveDate, timeZone: timeZone)
        guard input.startMonthKey >= purchaseMonthKey else {
            throw BudgetExpenseSmoothingError.invalidMonth
        }

        let key = BudgetSmoothingTransactionKey(
            accountIDIndex: accountIDIndex,
            bankTransactionID: bankTransactionID
        )
        let matches = try modelContext.fetch(FetchDescriptor<BudgetSmoothingPlan>())
            .filter {
                BudgetSmoothingTransactionKey(
                    accountIDIndex: $0.accountIDIndex,
                    bankTransactionID: $0.bankTransactionID
                ) == key
            }
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.uuid.uuidString < $1.uuid.uuidString
            }

        let plan: BudgetSmoothingPlan
        if let existing = matches.first {
            plan = existing
            for duplicate in matches.dropFirst() {
                modelContext.delete(duplicate)
            }
        } else {
            plan = BudgetSmoothingPlan(
                accountIDIndex: accountIDIndex,
                bankTransactionID: bankTransactionID,
                now: now
            )
            modelContext.insert(plan)
        }
        plan.name = name
        plan.startMonthKey = input.startMonthKey
        plan.durationMonths = input.durationMonths
        plan.modifiedAt = now
        try modelContext.save()
    }

    func removeBudgetExpenseSmoothing(
        accountIDIndex: String,
        bankTransactionID: String
    ) throws {
        try deleteBudgetExpenseSmoothingPlans(
            accountIDIndex: accountIDIndex,
            bankTransactionID: bankTransactionID
        )
        try modelContext.save()
    }

    /// Removes matching records in the caller's save transaction.
    func deleteBudgetExpenseSmoothingPlans(
        accountIDIndex: String,
        bankTransactionID: String
    ) throws {
        let key = BudgetSmoothingTransactionKey(
            accountIDIndex: accountIDIndex,
            bankTransactionID: bankTransactionID
        )
        for plan in try modelContext.fetch(FetchDescriptor<BudgetSmoothingPlan>())
        where BudgetSmoothingTransactionKey(
            accountIDIndex: plan.accountIDIndex,
            bankTransactionID: plan.bankTransactionID
        ) == key {
            modelContext.delete(plan)
        }
    }

    func deleteBudgetExpenseSmoothingPlans(accountIDIndex: String) throws {
        for plan in try modelContext.fetch(FetchDescriptor<BudgetSmoothingPlan>())
        where plan.accountIDIndex == accountIDIndex {
            modelContext.delete(plan)
        }
    }

    func exportBudgetExpenseSmoothingCSV() throws -> String {
        let transactions = try modelContext.fetch(FetchDescriptor<LedgerTransaction>())
        var transactionsByKey: [BudgetSmoothingTransactionKey: LedgerTransaction] = [:]
        for transaction in transactions {
            let key = BudgetSmoothingTransactionKey(
                accountIDIndex: transaction.accountIDIndex,
                bankTransactionID: transaction.bankTransactionID
            )
            transactionsByKey[key] = transaction
        }

        let plans = try modelContext.fetch(FetchDescriptor<BudgetSmoothingPlan>())
        let rows = plans.compactMap { plan -> BudgetExpenseSmoothingExportRow? in
            let key = BudgetSmoothingTransactionKey(
                accountIDIndex: plan.accountIDIndex,
                bankTransactionID: plan.bankTransactionID
            )
            guard let transaction = transactionsByKey[key],
                  let account = transaction.account else { return nil }
            let currency = account.currency
            return BudgetExpenseSmoothingExportRow(
                name: plan.name,
                purchase: transaction.payeeDescription,
                currency: currency.isCustom
                    ? (currency.customAbbreviation ?? currency.code)
                    : currency.code,
                amount: MinorUnits.string(
                    MinorUnits.absClamped(transaction.amountMinorUnits),
                    exponent: currency.exponent
                ),
                startMonth: plan.startMonthKey,
                months: plan.durationMonths
            )
        }.sorted {
            if $0.startMonth != $1.startMonth { return $0.startMonth < $1.startMonth }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Exporters.budgetExpenseSmoothingCSV(rows: rows)
    }
}
