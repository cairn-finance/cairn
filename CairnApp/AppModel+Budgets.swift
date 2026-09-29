import Foundation
import CairnCore

extension AppModel {
    @discardableResult
    func saveBudgetExpenseSmoothing(_ input: BudgetExpenseSmoothingInput) async -> Bool {
        do {
            try await engine.saveBudgetExpenseSmoothing(input)
            return true
        } catch {
            banner = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    @discardableResult
    func removeBudgetExpenseSmoothing(
        accountIDIndex: String,
        bankTransactionID: String
    ) async -> Bool {
        do {
            try await engine.removeBudgetExpenseSmoothing(
                accountIDIndex: accountIDIndex,
                bankTransactionID: bankTransactionID
            )
            return true
        } catch {
            banner = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func exportBudgetExpenseSmoothingCSV() async -> Data? {
        do {
            return Data(try await engine.exportBudgetExpenseSmoothingCSV().utf8)
        } catch {
            banner = String(localized: "Budget schedule export failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func resetBudgetSettings() async -> Bool {
        do {
            try await engine.resetBudgetSettings()
            return true
        } catch {
            banner = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    @discardableResult
    func applyBudgetRecommendations(
        _ selections: [BudgetLimitSelection],
        currency: Currency,
        monthKey: String,
        timeZoneIdentifier: String
    ) async -> Bool {
        do {
            try await engine.applyBudgetRecommendations(
                selections,
                currency: currency,
                monthKey: monthKey,
                timeZoneIdentifier: timeZoneIdentifier
            )
            return true
        } catch {
            banner = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    @discardableResult
    // Each parameter maps directly to the budget operation passed to the engine.
    // swiftlint:disable:next function_parameter_count
    func setBudgetLimit(
        categoryUUID: UUID,
        currency: Currency,
        monthKey: String,
        amountMinorUnits: Int64,
        isMonthOverride: Bool,
        isEnabled: Bool,
        timeZoneIdentifier: String
    ) async -> Bool {
        do {
            try await engine.setBudgetLimit(
                categoryUUID: categoryUUID,
                currency: currency,
                monthKey: monthKey,
                amountMinorUnits: amountMinorUnits,
                isMonthOverride: isMonthOverride,
                isEnabled: isEnabled,
                timeZoneIdentifier: timeZoneIdentifier
            )
            return true
        } catch {
            banner = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }
}
