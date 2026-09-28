import Foundation
import SwiftData

public enum BudgetManagementError: Error, LocalizedError, Equatable {
    case invalidAmount
    case categoryNotFound
    case notSpendingCategory
    case categoryArchived
    case categoryAlreadyConfigured
    case invalidMonth

    public var errorDescription: String? {
        switch self {
        case .invalidAmount: "Enter a budget amount of zero or more."
        case .categoryNotFound: "That category no longer exists."
        case .notSpendingCategory: "Choose a spending category for a budget limit."
        case .categoryArchived: "Unhide this category before adding a budget limit."
        case .categoryAlreadyConfigured: "A selected category already has a budget. Refresh suggestions and try again."
        case .invalidMonth: "Choose a valid budget month."
        }
    }
}

public struct BudgetLimitSelection: Sendable, Hashable {
    public let categoryUUID: UUID
    public let amountMinorUnits: Int64

    public init(categoryUUID: UUID, amountMinorUnits: Int64) {
        self.categoryUUID = categoryUUID
        self.amountMinorUnits = amountMinorUnits
    }
}

public extension SyncEngine {
    /// Saves a recurring limit or a one-month override. Encrypted fields are
    /// matched in memory because CloudKit cannot query them.
    func setBudgetLimit(
        categoryUUID: UUID,
        currency: Currency,
        monthKey: String,
        amountMinorUnits: Int64,
        isMonthOverride: Bool,
        isEnabled: Bool,
        timeZoneIdentifier: String,
        now: Date = .now
    ) throws {
        guard amountMinorUnits >= 0 else { throw BudgetManagementError.invalidAmount }
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier),
              BudgetCalculator.startOfMonth(monthKey, timeZone: timeZone) != nil else {
            throw BudgetManagementError.invalidMonth
        }
        let categoryDescriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.uuid == categoryUUID })
        guard let category = try modelContext.fetch(categoryDescriptor).first else {
            throw BudgetManagementError.categoryNotFound
        }
        guard !category.isArchived || !isEnabled else { throw BudgetManagementError.categoryArchived }
        let excludedNames = ["Income", "Transfers", "Credit Card Payments", "Loan Payments", "Uncategorized"]
        guard !excludedNames.contains(where: { $0.caseInsensitiveCompare(category.name) == .orderedSame }) else {
            throw BudgetManagementError.notSpendingCategory
        }

        let allSettings = try modelContext.fetch(FetchDescriptor<CategoryBudget>())
        let matching = allSettings.filter {
            $0.categoryUUID == categoryUUID
                && $0.currency == currency
                && $0.monthKey == monthKey
                && $0.isMonthOverride == isMonthOverride
        }
        let setting: CategoryBudget
        if let existing = matching.sorted(by: {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.uuid.uuidString < $1.uuid.uuidString
        }).first {
            setting = existing
        } else {
            setting = CategoryBudget(
                categoryUUID: categoryUUID,
                currency: currency,
                monthKey: monthKey,
                isMonthOverride: isMonthOverride,
                timeZoneIdentifier: timeZoneIdentifier
            )
            modelContext.insert(setting)
        }
        setting.currencyCode = currency.code
        setting.currencyExponent = currency.exponent
        setting.isCustomCurrency = currency.isCustom
        setting.customCurrencyName = currency.customName
        setting.customCurrencyAbbreviation = currency.customAbbreviation
        setting.amountMinorUnits = amountMinorUnits
        setting.isEnabled = isEnabled
        setting.timeZoneIdentifier = timeZoneIdentifier
        setting.modifiedAt = now
        if !isMonthOverride {
            for override in allSettings where override.categoryUUID == categoryUUID
                && override.currency == currency
                && override.monthKey == monthKey
                && override.isMonthOverride {
                modelContext.delete(override)
            }
        }
        try modelContext.save()
    }

    /// Applies a reviewed set of starting limits in one save. Existing settings
    /// are never replaced by recommendations.
    func applyBudgetRecommendations(
        _ selections: [BudgetLimitSelection],
        currency: Currency,
        monthKey: String,
        timeZoneIdentifier: String,
        now: Date = .now
    ) throws {
        guard !selections.isEmpty, selections.allSatisfy({ $0.amountMinorUnits > 0 }) else {
            throw BudgetManagementError.invalidAmount
        }
        guard Set(selections.map(\.categoryUUID)).count == selections.count else {
            throw BudgetManagementError.categoryAlreadyConfigured
        }
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier),
              BudgetCalculator.startOfMonth(monthKey, timeZone: timeZone) != nil else {
            throw BudgetManagementError.invalidMonth
        }

        let selectedIDs = Set(selections.map(\.categoryUUID))
        let categories = try modelContext.fetch(FetchDescriptor<Category>()).filter {
            selectedIDs.contains($0.uuid)
        }
        guard categories.count == selectedIDs.count else { throw BudgetManagementError.categoryNotFound }

        let excludedNames = ["Income", "Transfers", "Credit Card Payments", "Loan Payments", "Uncategorized"]
        for category in categories {
            guard !category.isArchived else { throw BudgetManagementError.categoryArchived }
            guard !excludedNames.contains(where: { $0.caseInsensitiveCompare(category.name) == .orderedSame }) else {
                throw BudgetManagementError.notSpendingCategory
            }
        }

        let existing = try modelContext.fetch(FetchDescriptor<CategoryBudget>())
        let settings = existing.map {
            BudgetSetting(
                uuid: $0.uuid,
                categoryUUID: $0.categoryUUID,
                currency: $0.currency,
                monthKey: $0.monthKey,
                amountMinorUnits: $0.amountMinorUnits,
                isMonthOverride: $0.isMonthOverride,
                isEnabled: $0.isEnabled,
                timeZoneIdentifier: $0.timeZoneIdentifier,
                modifiedAt: $0.modifiedAt
            )
        }
        let effective = BudgetCalculator.effectiveSettings(settings, monthKey: monthKey, currency: currency)
        guard selectedIDs.allSatisfy({ effective[$0]?.isEnabled != true }) else {
            throw BudgetManagementError.categoryAlreadyConfigured
        }

        let amounts = Dictionary(uniqueKeysWithValues: selections.map { ($0.categoryUUID, $0.amountMinorUnits) })
        for category in categories {
            guard let amount = amounts[category.uuid] else { continue }
            let setting: CategoryBudget
            if let existingRule = existing.filter({
                $0.categoryUUID == category.uuid && $0.currency == currency
                    && $0.monthKey == monthKey && !$0.isMonthOverride
            }).sorted(by: { $0.modifiedAt > $1.modifiedAt }).first {
                setting = existingRule
            } else {
                setting = CategoryBudget(categoryUUID: category.uuid, currency: currency, monthKey: monthKey)
                modelContext.insert(setting)
            }
            setting.currencyCode = currency.code
            setting.currencyExponent = currency.exponent
            setting.isCustomCurrency = currency.isCustom
            setting.customCurrencyName = currency.customName
            setting.customCurrencyAbbreviation = currency.customAbbreviation
            setting.amountMinorUnits = amount
            setting.isEnabled = true
            setting.timeZoneIdentifier = timeZoneIdentifier
            setting.modifiedAt = now
            for override in existing where override.categoryUUID == category.uuid
                && override.currency == currency
                && override.monthKey == monthKey
                && override.isMonthOverride {
                modelContext.delete(override)
            }
        }
        try modelContext.save()
    }

    func budgetCount(categoryUUID: UUID) throws -> Int {
        try modelContext.fetch(FetchDescriptor<CategoryBudget>()).filter { $0.categoryUUID == categoryUUID }.count
    }

    /// Removes every recurring limit and monthly override, across currencies.
    /// Categories, accounts, and transactions are not changed.
    func resetBudgetSettings() throws {
        for setting in try modelContext.fetch(FetchDescriptor<CategoryBudget>()) {
            modelContext.delete(setting)
        }
        try modelContext.save()
    }

    func exportBudgetRows() throws -> [BudgetExportRow] {
        let categories = try modelContext.fetch(FetchDescriptor<Category>())
        let names = Dictionary(categories.map { ($0.uuid, $0.name) }, uniquingKeysWith: { first, _ in first })
        return try modelContext.fetch(FetchDescriptor<CategoryBudget>())
            .map { setting in
                BudgetExportRow(
                    category: names[setting.categoryUUID] ?? "Archived category",
                    currency: setting.currency.isCustom
                        ? (setting.currency.customAbbreviation ?? setting.currency.code)
                        : setting.currency.code,
                    month: setting.monthKey,
                    amount: MinorUnits.string(setting.amountMinorUnits, exponent: setting.currency.exponent),
                    applies: setting.isMonthOverride ? "This month only" : "This month forward",
                    enabled: setting.isEnabled,
                    timeZone: setting.timeZoneIdentifier
                )
            }
            .sorted {
                if $0.category != $1.category {
                    return $0.category.localizedStandardCompare($1.category) == .orderedAscending
                }
                if $0.currency != $1.currency { return $0.currency < $1.currency }
                return $0.month < $1.month
            }
    }

    func exportBudgetsCSV() throws -> String {
        Exporters.budgetsCSV(rows: try exportBudgetRows())
    }
}
