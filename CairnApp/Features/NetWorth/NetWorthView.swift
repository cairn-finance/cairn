import SwiftUI
import SwiftData
import Charts
import CairnCore

struct NetWorthView: View {
    @Query private var accounts: [Account]
    @Query private var settings: [AppSettings]

    @State private var range: RangeOption = .ninetyDays

    enum RangeOption: String, CaseIterable, Identifiable {
        case thirtyDays, ninetyDays, oneYear
        var id: String { rawValue }
        var title: String {
            switch self {
            case .thirtyDays: "30D"
            case .ninetyDays: "90D"
            case .oneYear: "1Y"
            }
        }
        var days: Int {
            switch self {
            case .thirtyDays: 30
            case .ninetyDays: 90
            case .oneYear: 365
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if visibleTotals.isEmpty {
                    EmptyStateView(
                        systemImage: "chart.line.uptrend.xyaxis",
                        title: "Nothing to chart yet",
                        message: "Connect a bank and sync to build your net worth history."
                    )
                    .padding(.top, 40)
                } else {
                    chartCard
                    totalsCard
                }
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Net Worth")
    }

    private var homeCurrency: Currency {
        let code = settings.first?.homeCurrencyCode ?? "USD"
        return Currency(code: code, exponent: Currency.defaultExponent(forISOCode: code))
    }

    private var visibleTotals: [CurrencyTotal] {
        let included = accounts.filter { !$0.isHidden && $0.includeInNetWorth }
        let grouped = Dictionary(grouping: included) { $0.currency.code }
        return grouped.compactMap { _, group in
            guard let currency = group.first?.currency else { return nil }
            return CurrencyTotal(
                currency: currency,
                totalMinorUnits: group.reduce(Int64(0)) { $0 + $1.balanceMinorUnits }
            )
        }
        .sorted { $0.currency.code < $1.currency.code }
    }

    private var primaryCurrency: Currency {
        if visibleTotals.contains(where: { $0.currency.code == homeCurrency.code }) {
            return homeCurrency
        }
        return visibleTotals.first?.currency ?? homeCurrency
    }

    private var series: [BalanceHistory.Entry] {
        let relevant = accounts.filter {
            !$0.isHidden && $0.includeInNetWorth && $0.currency.code == primaryCurrency.code
        }
        return relevant.flatMap { account in
            (account.transactions ?? [])
                .filter { !$0.isPending }
                .map { BalanceHistory.Entry(date: $0.effectiveDate, amountMinorUnits: $0.amountMinorUnits) }
        }
    }

    private var currentTotal: Int64 {
        visibleTotals.first { $0.currency.code == primaryCurrency.code }?.totalMinorUnits ?? 0
    }

    private var dailyBalances: [(date: Date, balanceMinorUnits: Int64)] {
        let end = Calendar.current.startOfDay(for: .now)
        guard let start = Calendar.current.date(byAdding: .day, value: -range.days, to: end) else {
            return []
        }
        return BalanceHistory.dailyBalances(
            from: start,
            through: end,
            currentBalanceMinorUnits: currentTotal,
            transactions: series
        )
    }

    private var chartCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Net Worth")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                AmountText(
                    money: Money(minorUnits: currentTotal, currency: primaryCurrency),
                    font: .system(.largeTitle, design: .rounded, weight: .bold)
                )
                .fixedSize(horizontal: false, vertical: true)
                Picker("Range", selection: $range) {
                    ForEach(RangeOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Chart(dailyBalances, id: \.date) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Balance", dollarValue(point.balanceMinorUnits))
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Balance", dollarValue(point.balanceMinorUnits))
                    )
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 200)
            }
        }
    }

    private var totalsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Balances by currency")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(visibleTotals) { total in
                    HStack {
                        Text(total.currency.displayLabel)
                        Spacer()
                        AmountText(money: Money(minorUnits: total.totalMinorUnits, currency: total.currency), font: .body.weight(.medium))
                    }
                }
                if visibleTotals.count > 1 {
                    Text("Exchange rates are not used. Totals are kept per currency.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func dollarValue(_ minorUnits: Int64) -> Double {
        NSDecimalNumber(decimal: MinorUnits.decimal(minorUnits, exponent: primaryCurrency.exponent)).doubleValue
    }
}
