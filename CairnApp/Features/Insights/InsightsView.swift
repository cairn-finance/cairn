import Foundation
import SwiftUI
import SwiftData
import Charts
import CairnCore

/// Month-over-month spending, income, and category comparison. Everything is
/// computed on-device from the synced store.
struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Account> { $0.isHidden == false })
    private var accounts: [Account]
    @Query private var settings: [AppSettings]

    @State private var month: Date = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now

    var body: some View {
        let data = snapshot
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                monthSelector

                if currencyAccounts.isEmpty {
                    EmptyStateView(
                        systemImage: "chart.bar.xaxis",
                        title: "No accounts to analyze",
                        message: "Connect a bank or add an account to see spending insights."
                    )
                    .padding(.top, 40)
                } else {
                    summaryCard(data)
                    trendCard(data)
                    categoryCard(data)
                    merchantsCard(data)
                    categorizeCard
                }
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Insights")
        .task { await model.refreshCategorizationCounts() }
    }

    // MARK: - Currency & data

    private var homeCurrency: Currency {
        let code = settings.first?.homeCurrencyCode ?? "USD"
        return Currency(code: code, exponent: Currency.defaultExponent(forISOCode: code))
    }

    private var primaryCurrency: Currency {
        if accounts.contains(where: { $0.currency.code == homeCurrency.code }) {
            return homeCurrency
        }
        return accounts.first?.currency ?? homeCurrency
    }

    private var currencyAccounts: [Account] {
        accounts.filter { $0.currency.code == primaryCurrency.code }
    }

    private var snapshot: InsightsSnapshot {
        InsightsCalculator.snapshot(
            transactions: insightTransactions,
            month: month,
            historyMonths: 6,
            now: .now
        )
    }

    private var insightTransactions: [InsightTransaction] {
        currencyAccounts.flatMap { account in
            (account.transactions ?? []).map { transaction in
                InsightTransaction(
                    date: transaction.effectiveDate,
                    amountMinorUnits: transaction.amountMinorUnits,
                    categoryName: transaction.effectiveCategory?.name,
                    categoryColorHex: transaction.effectiveCategory?.colorHex,
                    merchant: transaction.normalizedMerchant.isEmpty
                        ? transaction.payeeDescription
                        : transaction.normalizedMerchant,
                    accountName: account.displayName,
                    isTransfer: transaction.isTransfer,
                    isIgnored: transaction.isIgnored,
                    isPending: transaction.isPending
                )
            }
        }
    }

    // MARK: - Month navigation

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(month, equalTo: .now, toGranularity: .month)
    }

    private var monthSelector: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left").font(.headline)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(month, format: .dateTime.month(.wide).year())
                .font(.headline)
                .contentTransition(.numericText())

            Spacer()

            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right").font(.headline)
            }
            .buttonStyle(.plain)
            .disabled(isCurrentMonth)
            .opacity(isCurrentMonth ? 0.3 : 1)
        }
        .padding(.horizontal, 4)
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: month) else { return }
        guard next <= .now || Calendar.current.isDate(next, equalTo: .now, toGranularity: .month) else { return }
        withAnimation(.snappy) { month = next }
    }

    // MARK: - Cards

    private func summaryCard(_ data: InsightsSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Spent in \(data.monthStart.formatted(.dateTime.month(.wide)))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    AmountText(
                        money: Money(minorUnits: data.current.spendingMinorUnits, currency: primaryCurrency),
                        font: .system(.largeTitle, design: .rounded, weight: .bold)
                    )
                    if let change = data.spendingChangeRatio {
                        changePill(change, higherIsBad: true)
                    }
                }

                HStack(spacing: 16) {
                    metric("Income", data.current.incomeMinorUnits, CairnTheme.positive)
                    metric(
                        "Net",
                        data.current.netMinorUnits,
                        data.current.netMinorUnits >= 0 ? CairnTheme.positive : CairnTheme.negative
                    )
                    metric("Avg / day", data.averageDailySpending(), CairnTheme.neutral)
                }
            }
        }
    }

    private func metric(_ title: String, _ minorUnits: Int64, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            AmountText(
                money: Money(minorUnits: minorUnits, currency: primaryCurrency),
                font: .callout.weight(.semibold),
                colorOverride: tint
            )
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct TrendPoint: Identifiable {
        let id = UUID()
        let month: Date
        let kind: String
        let amount: Double
    }

    private func trendCard(_ data: InsightsSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Last 6 months")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Chart(trendPoints(data)) { point in
                    BarMark(
                        x: .value("Month", point.month, unit: .month),
                        y: .value("Amount", point.amount)
                    )
                    .foregroundStyle(by: .value("Type", point.kind))
                    .position(by: .value("Type", point.kind))
                    .cornerRadius(4)
                }
                .chartForegroundStyleScale([
                    "Spending": CairnTheme.negative,
                    "Income": CairnTheme.positive,
                ])
                .chartLegend(position: .bottom, spacing: 8)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(shortCurrency(amount))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .frame(height: 190)
            }
        }
    }

    private func trendPoints(_ data: InsightsSnapshot) -> [TrendPoint] {
        data.months.flatMap { totals in
            [
                TrendPoint(month: totals.monthStart, kind: "Spending", amount: dollars(totals.spendingMinorUnits)),
                TrendPoint(month: totals.monthStart, kind: "Income", amount: dollars(totals.incomeMinorUnits)),
            ]
        }
    }

    private func categoryCard(_ data: InsightsSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Spending by category")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if data.previous.spendingMinorUnits > 0 {
                        Text("vs last month")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if data.categories.isEmpty {
                    Text("No spending recorded this month.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(data.categories.prefix(8)) { slice in
                        categoryRow(slice, in: data)
                    }
                }
            }
        }
    }

    private func categoryRow(_ slice: CategoryBreakdown, in data: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(CairnTheme.color(hex: slice.colorHex))
                    .frame(width: 9, height: 9)
                Text(slice.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let change = slice.changeRatio {
                    changePill(change, higherIsBad: true)
                }
                AmountText(
                    money: Money(minorUnits: slice.amountMinorUnits, currency: primaryCurrency),
                    font: .subheadline.weight(.semibold)
                )
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(CairnTheme.color(hex: slice.colorHex))
                        .frame(width: max(4, geometry.size.width * fraction(slice, in: data)))
                }
            }
            .frame(height: 6)
        }
    }

    private func fraction(_ slice: CategoryBreakdown, in data: InsightsSnapshot) -> Double {
        let largest = data.categories.map(\.amountMinorUnits).max() ?? 1
        guard largest > 0 else { return 0 }
        return Double(slice.amountMinorUnits) / Double(largest)
    }

    private func merchantsCard(_ data: InsightsSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Top merchants")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                if data.topMerchants.isEmpty {
                    Text("No merchants yet this month.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(data.topMerchants.enumerated()), id: \.element.id) { index, merchant in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .leading)
                            Text(merchant.name)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            AmountText(
                                money: Money(minorUnits: merchant.amountMinorUnits, currency: primaryCurrency),
                                font: .callout.weight(.medium)
                            )
                        }
                        if index < min(data.topMerchants.count, 8) - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var categorizeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Categorization")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                statusLine

                Text("Rules and your past corrections run first, automatically after every sync and import. "
                    + "When available, Apple Intelligence’s on-device model places what’s left. "
                    + "Transaction text never leaves your device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(AppleIntelligenceCategorizer.statusDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.categorizationState {
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Categorizing automatically…")
                    .font(.callout)
            }
        case let .finished(categorized, counts):
            if counts.total == 0 {
                allCategorizedLabel(categorized: categorized)
            } else if counts.pendingModel > 0, automaticModelEnabled {
                Label(
                    "\(counts.pendingModel) transaction\(counts.pendingModel == 1 ? "" : "s") will be categorized automatically.",
                    systemImage: "clock"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                Label(
                    "\(counts.total) transaction\(counts.total == 1 ? "" : "s") need a category.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        case .idle:
            if model.categorizationCounts.total == 0 {
                allCategorizedLabel(categorized: 0)
            } else {
                Label(
                    "\(model.categorizationCounts.total) transaction\(model.categorizationCounts.total == 1 ? "" : "s") will be categorized automatically.",
                    systemImage: "clock"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var automaticModelEnabled: Bool {
        model.useAppleIntelligence && AppleIntelligenceCategorizer.isAvailable
    }

    private func allCategorizedLabel(categorized: Int) -> some View {
        Label(
            categorized > 0
                ? "Categorized \(categorized) transaction\(categorized == 1 ? "" : "s"). All caught up."
                : "All transactions are categorized.",
            systemImage: "checkmark.circle.fill"
        )
        .font(.callout)
        .foregroundStyle(CairnTheme.positive)
    }

    // MARK: - Helpers

    private func changePill(_ ratio: Double, higherIsBad: Bool) -> some View {
        let percent = Int((abs(ratio) * 100).rounded())
        let isUp = ratio >= 0
        let good = higherIsBad ? !isUp : isUp
        let color = percent == 0 ? CairnTheme.neutral : (good ? CairnTheme.positive : CairnTheme.negative)

        return HStack(spacing: 2) {
            Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
            Text("\(percent)%")
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .fixedSize()
    }

    private func dollars(_ minorUnits: Int64) -> Double {
        NSDecimalNumber(decimal: MinorUnits.decimal(minorUnits, exponent: primaryCurrency.exponent)).doubleValue
    }

    private func shortCurrency(_ value: Double) -> String {
        if primaryCurrency.isCustom {
            return value.formatted(.number.notation(.compactName).precision(.fractionLength(0)))
        }
        return value.formatted(
            .currency(code: primaryCurrency.code).notation(.compactName).precision(.fractionLength(1))
        )
    }
}
