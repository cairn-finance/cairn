import Foundation
import SwiftData

/// A currency-safe aggregate amount shared with Home Screen widgets.
public struct FinancialWidgetAmount: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let currency: Currency
    public let amountMinorUnits: Int64

    public var id: String { currency.stableIdentifier }

    public init(currency: Currency, amountMinorUnits: Int64) {
        self.currency = currency
        self.amountMinorUnits = amountMinorUnits
    }
}

/// Aggregate financial values shared with widgets. This intentionally contains
/// no account, institution, merchant, or transaction identifiers or names.
public struct FinancialWidgetSnapshot: Codable, Equatable, Sendable {
    public static let sharedDefaultsKey = "cairn.financial-widget.snapshot"

    public let generatedAt: Date
    public let primaryCurrency: Currency
    public let netWorth: [FinancialWidgetAmount]
    public let monthToDateSpend: [FinancialWidgetAmount]
    public let monthStart: Date

    public init(
        generatedAt: Date,
        primaryCurrency: Currency,
        netWorth: [FinancialWidgetAmount],
        monthToDateSpend: [FinancialWidgetAmount],
        monthStart: Date
    ) {
        self.generatedAt = generatedAt
        self.primaryCurrency = primaryCurrency
        self.netWorth = netWorth
        self.monthToDateSpend = monthToDateSpend
        self.monthStart = monthStart
    }

    public func isFresh(at now: Date = .now, maximumAge: TimeInterval = 26 * 60 * 60) -> Bool {
        let age = now.timeIntervalSince(generatedAt)
        return age >= 0 && age <= maximumAge
    }

    public func includesCurrentMonth(at now: Date = .now, calendar: Calendar = .current) -> Bool {
        calendar.dateInterval(of: .month, for: now)?.start == monthStart
    }
}

public struct FinancialWidgetAccount: Sendable {
    public let currency: Currency
    public let balanceMinorUnits: Int64
    public let isHidden: Bool
    public let includeInNetWorth: Bool

    public init(currency: Currency, balanceMinorUnits: Int64, isHidden: Bool, includeInNetWorth: Bool) {
        self.currency = currency
        self.balanceMinorUnits = balanceMinorUnits
        self.isHidden = isHidden
        self.includeInNetWorth = includeInNetWorth
    }
}

public struct FinancialWidgetTransaction: Sendable {
    public let currency: Currency
    public let amountMinorUnits: Int64
    public let effectiveDate: Date
    public let isPending: Bool
    public let isIgnored: Bool
    public let countsAsTransfer: Bool

    public init(
        currency: Currency,
        amountMinorUnits: Int64,
        effectiveDate: Date,
        isPending: Bool,
        isIgnored: Bool,
        countsAsTransfer: Bool
    ) {
        self.currency = currency
        self.amountMinorUnits = amountMinorUnits
        self.effectiveDate = effectiveDate
        self.isPending = isPending
        self.isIgnored = isIgnored
        self.countsAsTransfer = countsAsTransfer
    }
}

public enum FinancialWidgetSnapshotBuilder {
    public static func make(
        accounts: [FinancialWidgetAccount],
        transactions: [FinancialWidgetTransaction],
        homeCurrency: Currency,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> FinancialWidgetSnapshot {
        let monthInterval = calendar.dateInterval(of: .month, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 0)
        var balances: [Currency: Int64] = [:]
        for account in accounts where !account.isHidden && account.includeInNetWorth {
            balances[account.currency] = MinorUnits.addClamped(
                balances[account.currency] ?? 0,
                account.balanceMinorUnits
            )
        }

        var spending: [Currency: Int64] = [:]
        for transaction in transactions where transaction.effectiveDate >= monthInterval.start
            && transaction.effectiveDate < monthInterval.end
            && transaction.effectiveDate <= now
            && !transaction.isPending
            && !transaction.isIgnored
            && !transaction.countsAsTransfer
            && transaction.amountMinorUnits < 0 {
            spending[transaction.currency] = MinorUnits.addClamped(
                spending[transaction.currency] ?? 0,
                MinorUnits.absClamped(transaction.amountMinorUnits)
            )
        }

        let netWorth = amounts(from: balances)
        let primaryCurrency: Currency
        if netWorth.contains(where: { $0.currency == homeCurrency }) {
            primaryCurrency = homeCurrency
        } else if let sameCode = netWorth.first(where: { $0.currency.code == homeCurrency.code }) {
            primaryCurrency = sameCode.currency
        } else {
            primaryCurrency = netWorth.first?.currency ?? homeCurrency
        }

        return FinancialWidgetSnapshot(
            generatedAt: now,
            primaryCurrency: primaryCurrency,
            netWorth: netWorth,
            monthToDateSpend: amounts(from: spending.filter { $0.value > 0 }),
            monthStart: monthInterval.start
        )
    }

    private static func amounts(from totals: [Currency: Int64]) -> [FinancialWidgetAmount] {
        totals.map { FinancialWidgetAmount(currency: $0.key, amountMinorUnits: $0.value) }
            .sorted { $0.currency.stableIdentifier < $1.currency.stableIdentifier }
    }
}

/// Fetches only value snapshots off the main actor; model objects never leave
/// this actor or the context that created them.
@ModelActor
public actor FinancialWidgetFetcher {
    public func snapshot(at now: Date = .now, calendar: Calendar = .current) throws -> FinancialWidgetSnapshot {
        let accounts = try modelContext.fetch(FetchDescriptor<Account>()).map {
            FinancialWidgetAccount(
                currency: $0.currency,
                balanceMinorUnits: $0.balanceMinorUnits,
                isHidden: $0.isHidden,
                includeInNetWorth: $0.includeInNetWorth
            )
        }
        let transactions = try modelContext.fetch(
            FetchDescriptor<LedgerTransaction>(predicate: #Predicate { !$0.isPending })
        ).map {
            FinancialWidgetTransaction(
                currency: $0.account?.currency ?? Currency(code: "USD", exponent: $0.currencyExponent),
                amountMinorUnits: $0.amountMinorUnits,
                effectiveDate: $0.effectiveDate,
                isPending: $0.isPending,
                isIgnored: $0.isIgnored,
                countsAsTransfer: $0.countsAsTransfer
            )
        }
        let settings = try modelContext.fetch(FetchDescriptor<AppSettings>())
        let homeCode = settings.first?.homeCurrencyCode ?? "USD"
        let homeCurrency = Currency(code: homeCode, exponent: Currency.defaultExponent(forISOCode: homeCode))
        return FinancialWidgetSnapshotBuilder.make(
            accounts: accounts,
            transactions: transactions,
            homeCurrency: homeCurrency,
            now: now,
            calendar: calendar
        )
    }
}
