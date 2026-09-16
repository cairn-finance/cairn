import Foundation
import SwiftData
import CairnCore

struct CurrencyTotal: Identifiable, Hashable {
    var id: String { currency.code }
    let currency: Currency
    let totalMinorUnits: Int64
}

/// Net-worth arithmetic shared by the Home hero, the Net Worth screen, and
/// account detail. Totals are never summed across currencies.
enum NetWorthMath {
    static func homeCurrency(settings: [AppSettings]) -> Currency {
        let code = settings.first?.homeCurrencyCode ?? "USD"
        return Currency(code: code, exponent: Currency.defaultExponent(forISOCode: code))
    }

    /// Accounts that count toward net worth: visible and opted in.
    static func included(_ accounts: [Account]) -> [Account] {
        accounts.filter { !$0.isHidden && $0.includeInNetWorth }
    }

    static func totals(accounts: [Account]) -> [CurrencyTotal] {
        let grouped = Dictionary(grouping: included(accounts)) { $0.currency.code }
        return grouped.compactMap { _, group in
            guard let currency = group.first?.currency else { return nil }
            return CurrencyTotal(
                currency: currency,
                totalMinorUnits: group.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.balanceMinorUnits) }
            )
        }
        .sorted { $0.currency.code < $1.currency.code }
    }

    /// The home currency when it has accounts, otherwise the first currency.
    static func primaryCurrency(totals: [CurrencyTotal], home: Currency) -> Currency {
        if totals.contains(where: { $0.currency.code == home.code }) { return home }
        return totals.first?.currency ?? home
    }

    /// Assets (positive balances) and liabilities (negative balances or
    /// liability-type accounts) in one currency.
    static func assetsAndLiabilities(accounts: [Account], currency: Currency) -> (assets: Int64, liabilities: Int64) {
        var assets: Int64 = 0
        var liabilities: Int64 = 0
        for account in included(accounts) where account.currency.code == currency.code {
            if account.accountType.isLiability || account.balanceMinorUnits < 0 {
                liabilities += abs(account.balanceMinorUnits)
            } else {
                assets += account.balanceMinorUnits
            }
        }
        return (assets, liabilities)
    }

    /// A daily balance series over the trailing `days` for one currency.
    static func series(
        accounts: [Account],
        currency: Currency,
        days: Int,
        calendar: Calendar = .current
    ) -> [(date: Date, balanceMinorUnits: Int64)] {
        let relevant = included(accounts).filter { $0.currency.code == currency.code }
        let entries = relevant.flatMap { account in
            (account.transactions ?? [])
                .filter { !$0.isPending }
                .map { BalanceHistory.Entry(date: $0.effectiveDate, amountMinorUnits: $0.amountMinorUnits) }
        }
        let current = relevant.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.balanceMinorUnits) }
        return balances(current: current, entries: entries, days: days, calendar: calendar)
    }

    /// A daily balance series for a single account.
    static func series(account: Account, days: Int, calendar: Calendar = .current) -> [(date: Date, balanceMinorUnits: Int64)] {
        let entries = (account.transactions ?? [])
            .filter { !$0.isPending }
            .map { BalanceHistory.Entry(date: $0.effectiveDate, amountMinorUnits: $0.amountMinorUnits) }
        return balances(current: account.balanceMinorUnits, entries: entries, days: days, calendar: calendar)
    }

    private static func balances(
        current: Int64,
        entries: [BalanceHistory.Entry],
        days: Int,
        calendar: Calendar
    ) -> [(date: Date, balanceMinorUnits: Int64)] {
        let end = calendar.startOfDay(for: .now)
        guard let start = calendar.date(byAdding: .day, value: -days, to: end) else { return [] }
        return BalanceHistory.dailyBalances(
            from: start,
            through: end,
            currentBalanceMinorUnits: current,
            transactions: entries,
            calendar: calendar
        )
    }

    /// Change between the first and last point of a series, as an absolute
    /// delta and a ratio (nil when the baseline is zero).
    static func change(in series: [(date: Date, balanceMinorUnits: Int64)]) -> (delta: Int64, ratio: Double?) {
        guard let first = series.first?.balanceMinorUnits, let last = series.last?.balanceMinorUnits else {
            return (0, nil)
        }
        let delta = last - first
        let ratio: Double? = first != 0 ? Double(delta) / Double(abs(first)) : nil
        return (delta, ratio)
    }

    static func doubleValue(_ minorUnits: Int64, currency: Currency) -> Double {
        NSDecimalNumber(decimal: MinorUnits.decimal(minorUnits, exponent: currency.exponent)).doubleValue
    }
}
