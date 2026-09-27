import Foundation
import CairnCore

extension AppModel {
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
