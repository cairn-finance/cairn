import Foundation
import SwiftData

public struct MerchantSpendTransaction: Sendable {
    public let merchantKey: String
    public let currency: Currency
    public let amountMinorUnits: Int64
    public let effectiveDate: Date
    public let isPending: Bool
    public let isIgnored: Bool
    public let countsAsTransfer: Bool

    public init(
        merchantKey: String,
        currency: Currency,
        amountMinorUnits: Int64,
        effectiveDate: Date,
        isPending: Bool,
        isIgnored: Bool,
        countsAsTransfer: Bool
    ) {
        self.merchantKey = merchantKey
        self.currency = currency
        self.amountMinorUnits = amountMinorUnits
        self.effectiveDate = effectiveDate
        self.isPending = isPending
        self.isIgnored = isIgnored
        self.countsAsTransfer = countsAsTransfer
    }
}

public struct MerchantSpendSummary: Equatable, Sendable {
    public let week: [FinancialWidgetAmount]
    public let month: [FinancialWidgetAmount]
    public let year: [FinancialWidgetAmount]
    public let weekStart: Date
    public let monthStart: Date
    public let yearStart: Date

    public init(
        week: [FinancialWidgetAmount],
        month: [FinancialWidgetAmount],
        year: [FinancialWidgetAmount],
        weekStart: Date,
        monthStart: Date,
        yearStart: Date
    ) {
        self.week = week
        self.month = month
        self.year = year
        self.weekStart = weekStart
        self.monthStart = monthStart
        self.yearStart = yearStart
    }
}

public enum MerchantSpendSummaryBuilder {
    public static func make(
        merchantKey: String,
        transactions: [MerchantSpendTransaction],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> MerchantSpendSummary {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        let yearStart = calendar.dateInterval(of: .year, for: now)?.start ?? calendar.startOfDay(for: now)
        var week: [Currency: Int64] = [:]
        var month: [Currency: Int64] = [:]
        var year: [Currency: Int64] = [:]

        for transaction in transactions where transaction.merchantKey == merchantKey
            && transaction.effectiveDate >= yearStart
            && transaction.effectiveDate <= now
            && !transaction.isPending
            && !transaction.isIgnored
            && !transaction.countsAsTransfer
            && transaction.amountMinorUnits < 0 {
            let amount = MinorUnits.absClamped(transaction.amountMinorUnits)
            year[transaction.currency] = MinorUnits.addClamped(year[transaction.currency] ?? 0, amount)
            if transaction.effectiveDate >= monthStart {
                month[transaction.currency] = MinorUnits.addClamped(month[transaction.currency] ?? 0, amount)
            }
            if transaction.effectiveDate >= weekStart {
                week[transaction.currency] = MinorUnits.addClamped(week[transaction.currency] ?? 0, amount)
            }
        }

        return MerchantSpendSummary(
            week: amounts(from: week),
            month: amounts(from: month),
            year: amounts(from: year),
            weekStart: weekStart,
            monthStart: monthStart,
            yearStart: yearStart
        )
    }

    private static func amounts(from totals: [Currency: Int64]) -> [FinancialWidgetAmount] {
        totals.map { FinancialWidgetAmount(currency: $0.key, amountMinorUnits: $0.value) }
            .sorted { $0.currency.stableIdentifier < $1.currency.stableIdentifier }
    }
}

/// Fetches merchant-only value data on a model actor and totals posted spending
/// without passing SwiftData objects to the view.
@ModelActor
public actor MerchantSpendFetcher {
    public func summary(
        for merchantKey: String,
        at now: Date = .now,
        calendar: Calendar = .current
    ) throws -> MerchantSpendSummary {
        let transactions = try modelContext.fetch(
            FetchDescriptor<LedgerTransaction>(predicate: #Predicate { !$0.isPending })
        ).map { transaction in
            let merchant = transaction.normalizedMerchant.isEmpty
                ? transaction.payeeDescription
                : transaction.normalizedMerchant
            return MerchantSpendTransaction(
                merchantKey: MerchantNormalizer.groupingKey(merchant),
                currency: transaction.account?.currency ?? Currency(code: "USD", exponent: transaction.currencyExponent),
                amountMinorUnits: transaction.amountMinorUnits,
                effectiveDate: transaction.effectiveDate,
                isPending: transaction.isPending,
                isIgnored: transaction.isIgnored,
                countsAsTransfer: transaction.countsAsTransfer
            )
        }
        return MerchantSpendSummaryBuilder.make(
            merchantKey: merchantKey,
            transactions: transactions,
            now: now,
            calendar: calendar
        )
    }
}
