import Foundation
import SwiftData

/// A transaction reduced to everything a row renders, plus its month/day
/// grouping inputs. List views draw from these immutable values instead of
/// re-reading a `LedgerTransaction`'s properties and relationships while SwiftUI
/// diffs, which keeps one changed transaction from re-evaluating every row.
///
/// The type is `Sendable`, so a background fetcher can build values and hand
/// them to the main actor.
public struct TransactionRowValue: Sendable, Hashable, Identifiable {
    /// Stable identity for list diffing. A transaction can appear under more
    /// than one account query, so the account's index is part of the key.
    public let id: String
    /// The model identity, kept so a row can lazily load its model for the
    /// detail screen or an edit sheet without the list holding the model. `nil`
    /// only for values built in tests from raw fields.
    public let persistentID: PersistentIdentifier?

    public let payeeDescription: String
    public let note: String?
    public let amountMinorUnits: Int64
    public let currency: Currency
    public let effectiveDate: Date

    public let isPending: Bool
    public let isIgnored: Bool
    public let isTransfer: Bool
    /// True when either the user's or the automatic category is a built-in
    /// money-movement category. Computed at mapping time because it considers
    /// both categories, not just the effective one.
    public let countsAsTransfer: Bool

    /// The effective category's display fields, when it has one.
    public let categoryName: String?
    public let categorySymbolName: String?
    public let categoryColorHex: String?
    /// The effective category's identity, for exact category filtering.
    public let categoryID: PersistentIdentifier?

    public let accountName: String?
    /// Tag names in relationship order, so the row's summary matches the model.
    public let tagNames: [String]
    /// Tag identities, so a tag filter can match exactly without comparing
    /// names (which need not be unique).
    public let tagIDs: [PersistentIdentifier]

    public init(
        id: String,
        persistentID: PersistentIdentifier?,
        payeeDescription: String,
        note: String? = nil,
        amountMinorUnits: Int64,
        currency: Currency,
        effectiveDate: Date,
        isPending: Bool,
        isIgnored: Bool,
        isTransfer: Bool,
        countsAsTransfer: Bool,
        categoryName: String?,
        categorySymbolName: String?,
        categoryColorHex: String?,
        categoryID: PersistentIdentifier? = nil,
        accountName: String?,
        tagNames: [String],
        tagIDs: [PersistentIdentifier] = []
    ) {
        self.id = id
        self.persistentID = persistentID
        self.payeeDescription = payeeDescription
        self.note = note
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
        self.effectiveDate = effectiveDate
        self.isPending = isPending
        self.isIgnored = isIgnored
        self.isTransfer = isTransfer
        self.countsAsTransfer = countsAsTransfer
        self.categoryName = categoryName
        self.categorySymbolName = categorySymbolName
        self.categoryColorHex = categoryColorHex
        self.categoryID = categoryID
        self.accountName = accountName
        self.tagNames = tagNames
        self.tagIDs = tagIDs
    }

    public var amount: Money {
        Money(minorUnits: amountMinorUnits, currency: currency)
    }

    /// True when the row belongs to the "Needs category" filter: no effective
    /// category, not money movement, and not ignored.
    public var needsCategory: Bool {
        categoryName == nil && !countsAsTransfer && !isIgnored
    }

    /// The composite identity used for list diffing. Both components are stored,
    /// non-encrypted fields on the model, so the key is cheap and stable for the
    /// life of the store.
    public static func stableID(
        accountIDIndex: String,
        bankTransactionID: String,
        persistentID: PersistentIdentifier?
    ) -> String {
        if accountIDIndex.isEmpty && bankTransactionID.isEmpty {
            guard let persistentID else { return "unidentified" }
            return String(describing: persistentID)
        }
        return "\(accountIDIndex)/\(bankTransactionID)"
    }
}

extension CairnSchemaV1.LedgerTransaction {
    /// Snapshots this transaction into a `Sendable` value. Reads every model
    /// property and relationship the UI needs exactly once.
    public func rowValue() -> TransactionRowValue {
        let category = effectiveCategory
        return TransactionRowValue(
            id: TransactionRowValue.stableID(
                accountIDIndex: accountIDIndex,
                bankTransactionID: bankTransactionID,
                persistentID: persistentModelID
            ),
            persistentID: persistentModelID,
            payeeDescription: payeeDescription,
            note: note,
            amountMinorUnits: amountMinorUnits,
            currency: account?.currency ?? Currency(code: "USD", exponent: currencyExponent),
            effectiveDate: effectiveDate,
            isPending: isPending,
            isIgnored: isIgnored,
            isTransfer: isTransfer,
            countsAsTransfer: countsAsTransfer,
            categoryName: category?.name,
            categorySymbolName: category?.symbolName,
            categoryColorHex: category?.colorHex,
            categoryID: category?.persistentModelID,
            accountName: account?.displayName,
            tagNames: (tags ?? []).map(\.name),
            tagIDs: (tags ?? []).map(\.persistentModelID)
        )
    }
}

/// Transactions for one calendar day, newest first, with the day's spending
/// already totaled so the view never re-reduces the rows.
public struct TransactionDaySection: Sendable, Identifiable {
    public let day: Date
    public let rows: [TransactionRowValue]
    /// Positive magnitude of the day's spending, excluding transfers and
    /// ignored rows.
    public let spentMinorUnits: Int64
    public let currency: Currency

    public var id: Date { day }

    public init(day: Date, rows: [TransactionRowValue], spentMinorUnits: Int64, currency: Currency) {
        self.day = day
        self.rows = rows
        self.spentMinorUnits = spentMinorUnits
        self.currency = currency
    }
}

/// One month's day sections, with the month's spending precomputed for the
/// pinned header.
public struct TransactionMonthSection: Sendable, Identifiable {
    public let month: Date
    public let days: [TransactionDaySection]
    public let spentMinorUnits: Int64
    public let currency: Currency

    public var id: Date { month }

    public init(month: Date, days: [TransactionDaySection], spentMinorUnits: Int64, currency: Currency) {
        self.month = month
        self.days = days
        self.spentMinorUnits = spentMinorUnits
        self.currency = currency
    }
}

/// Groups immutable row values into the month/day cards the transaction list
/// draws. Pure and `Sendable`: the caller snapshots once, then both the totals
/// and the structure come from these values.
public enum TransactionSectionBuilder {
    public static func months(
        from rows: [TransactionRowValue],
        calendar: Calendar = .current
    ) -> [TransactionMonthSection] {
        let byDay = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.effectiveDate) }
        let daySections = byDay.map { day, dayRows -> TransactionDaySection in
            let sorted = dayRows.sorted { $0.effectiveDate > $1.effectiveDate }
            return TransactionDaySection(
                day: day,
                rows: sorted,
                spentMinorUnits: spent(in: sorted),
                currency: sorted.first?.currency ?? .usd
            )
        }
        .sorted { $0.day > $1.day }

        let byMonth = Dictionary(grouping: daySections) {
            calendar.dateInterval(of: .month, for: $0.day)?.start ?? $0.day
        }
        return byMonth.map { month, days -> TransactionMonthSection in
            let sorted = days.sorted { $0.day > $1.day }
            let total = sorted.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.spentMinorUnits) }
            return TransactionMonthSection(
                month: month,
                days: sorted,
                spentMinorUnits: total,
                currency: sorted.first?.currency ?? .usd
            )
        }
        .sorted { $0.month > $1.month }
    }

    /// Spending magnitude for a set of rows, matching the Activity day total:
    /// negative, not money movement, and not ignored.
    public static func spent(in rows: [TransactionRowValue]) -> Int64 {
        rows.reduce(Int64(0)) { partial, row in
            guard row.amountMinorUnits < 0, !row.countsAsTransfer, !row.isIgnored else { return partial }
            return MinorUnits.addClamped(partial, MinorUnits.absClamped(row.amountMinorUnits))
        }
    }
}
