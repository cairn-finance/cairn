import Foundation
import SwiftUI
import SwiftData
import Charts
import CairnCore

/// Month-over-month spending, pace, and category comparison. Everything is
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
                monthChips

                if currencyAccounts.isEmpty {
                    EmptyStateView(
                        systemImage: "chart.bar.xaxis",
                        title: "No accounts to analyze",
                        message: "Connect a bank or add an account to see spending insights."
                    )
                    .padding(.top, 40)
                } else {
                    heroCard(data)
                    paceCard(data)
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
                    isTransfer: transaction.countsAsTransfer,
                    isIgnored: transaction.isIgnored,
                    isPending: transaction.isPending
                )
            }
        }
    }

    // MARK: - Month navigation

    private var currentMonthStart: Date {
        Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    }

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(month, equalTo: .now, toGranularity: .month)
    }

    private func isSelected(_ date: Date) -> Bool {
        Calendar.current.isDate(date, equalTo: month, toGranularity: .month)
    }

    private var recentMonths: [Date] {
        let calendar = Calendar.current
        var months = (0..<6).reversed().compactMap {
            calendar.date(byAdding: .month, value: -$0, to: currentMonthStart)
        }
        if !months.contains(where: { calendar.isDate($0, equalTo: month, toGranularity: .month) }) {
            months.insert(calendar.dateInterval(of: .month, for: month)?.start ?? month, at: 0)
        }
        return months
    }

    private var monthChips: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    shiftMonth(-1)
                } label: {
                    Image(systemName: "chevron.left").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(recentMonths, id: \.self) { candidate in
                                Button {
                                    withAnimation(.snappy) { month = candidate }
                                } label: {
                                    Text(candidate, format: .dateTime.month(.abbreviated).year(.twoDigits))
                                        .font(.subheadline.weight(isSelected(candidate) ? .semibold : .regular))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            isSelected(candidate) ? Color.accentColor : Color.clear,
                                            in: Capsule()
                                        )
                                        .foregroundStyle(isSelected(candidate) ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                                .id(candidate)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .onAppear { scrollToSelected(proxy) }
                    .onChange(of: month) { _, _ in scrollToSelected(proxy) }
                }

                Button {
                    shiftMonth(1)
                } label: {
                    Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(isCurrentMonth)
                .opacity(isCurrentMonth ? 0.3 : 1)
            }

            if !isCurrentMonth {
                Button("Back to this month") {
                    withAnimation(.snappy) { month = currentMonthStart }
                }
                .font(.caption)
            }
        }
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: month) else { return }
        guard next <= .now || Calendar.current.isDate(next, equalTo: .now, toGranularity: .month) else { return }
        withAnimation(.snappy) { month = next }
    }

    private func scrollToSelected(_ proxy: ScrollViewProxy) {
        guard let selected = recentMonths.first(where: { isSelected($0) }) else { return }
        withAnimation(.snappy) { proxy.scrollTo(selected, anchor: .center) }
    }

    // MARK: - Hero

    private func heroCard(_ data: InsightsSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(isCurrentMonth
                     ? "Spent this month"
                     : "Spent in \(data.monthStart.formatted(.dateTime.month(.wide)))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    AmountText(
                        money: Money(minorUnits: data.currentToDateSpending, currency: primaryCurrency),
                        font: .system(.largeTitle, design: .rounded, weight: .bold)
                    )
                    if let change = data.spendingChangeVsDate {
                        changePill(change, higherIsBad: true)
                    }
                }

                if isCurrentMonth, data.averageDailyPace > 0 {
                    Text("On pace for \(moneyText(data.projectedSpending)) by month end")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if data.previousToDateSpending > 0 {
                    Text("vs \(moneyText(data.previousToDateSpending)) at this point last month")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Divider()

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

    // MARK: - Pace

    private func idealPace(_ data: InsightsSnapshot) -> [PacePoint] {
        guard data.averageDailyPace > 0, data.lastDayWithData > 0 else { return [] }
        return (1...data.lastDayWithData).map { day in
            PacePoint(day: day, amountMinorUnits: data.averageDailyPace * Int64(day))
        }
    }

    private func paceCard(_ data: InsightsSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(isCurrentMonth ? "Pace this month" : "Pace")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if data.averageDailyPace > 0 {
                        Text("dashed = your usual pace")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if data.cumulative.isEmpty {
                    Text("No spending recorded yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Chart {
                        ForEach(data.cumulative) { point in
                            AreaMark(
                                x: .value("Day", point.day),
                                y: .value("Spent", dollars(point.amountMinorUnits))
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.30), Color.accentColor.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.monotone)
                        }
                        ForEach(data.cumulative) { point in
                            LineMark(
                                x: .value("Day", point.day),
                                y: .value("Spent", dollars(point.amountMinorUnits))
                            )
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.monotone)
                        }
                        ForEach(idealPace(data)) { point in
                            LineMark(
                                x: .value("Day", point.day),
                                y: .value("Spent", dollars(point.amountMinorUnits)),
                                series: .value("Series", "usual")
                            )
                            .foregroundStyle(Color.secondary.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .interpolationMethod(.linear)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: [1, 8, 15, 22, data.daysInMonth]) { value in
                            AxisValueLabel {
                                if let day = value.as(Int.self) { Text("\(day)") }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let amount = value.as(Double.self) { Text(shortCurrency(amount)) }
                            }
                        }
                    }
                    .frame(height: 170)
                }
            }
        }
    }

    // MARK: - Trend

    private func trendCard(_ data: InsightsSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Last 6 months")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    AmountText(
                        money: Money(minorUnits: data.current.spendingMinorUnits, currency: primaryCurrency),
                        font: .caption.weight(.semibold)
                    )
                }

                Chart(data.months) { totals in
                    BarMark(
                        x: .value("Month", totals.monthStart, unit: .month),
                        y: .value("Spending", dollars(totals.spendingMinorUnits))
                    )
                    .foregroundStyle(
                        isSelected(totals.monthStart)
                            ? Color.accentColor
                            : Color.accentColor.opacity(0.30)
                    )
                    .cornerRadius(4)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let amount = value.as(Double.self) { Text(shortCurrency(amount)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) {
                        AxisValueLabel(format: .dateTime.month(.narrow))
                    }
                }
                .frame(height: 150)
            }
        }
    }

    // MARK: - Categories

    private func categoryCard(_ data: InsightsSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Spending by category")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("tap to view")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if data.categories.isEmpty {
                    Text("No spending recorded this month.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(data.categories.prefix(8)) { slice in
                        NavigationLink {
                            InsightFilteredListView(
                                title: slice.name,
                                emptyMessage: "No transactions in this category for this month.",
                                currency: primaryCurrency,
                                scope: .category(name: slice.name, month: data.monthStart)
                            )
                        } label: {
                            categoryRow(slice, in: data)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func categoryRow(_ slice: CategoryBreakdown, in data: InsightsSnapshot) -> some View {
        let total = data.categories.reduce(Int64(0)) { $0 + $1.amountMinorUnits }
        let share = total > 0 ? Double(slice.amountMinorUnits) / Double(total) : 0
        let showChange = data.topMoverNames.contains(slice.name)
            && (slice.changeRatio.map { abs($0) >= 0.1 } ?? false)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(CairnTheme.color(hex: slice.colorHex))
                    .frame(width: 9, height: 9)
                Text(slice.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                AmountText(
                    money: Money(minorUnits: slice.amountMinorUnits, currency: primaryCurrency),
                    font: .subheadline.weight(.semibold)
                )
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
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

            HStack(spacing: 6) {
                Text(share.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if showChange, let change = slice.changeRatio {
                    changePill(change, higherIsBad: true)
                }
            }
        }
    }

    private func fraction(_ slice: CategoryBreakdown, in data: InsightsSnapshot) -> Double {
        let largest = data.categories.map(\.amountMinorUnits).max() ?? 1
        guard largest > 0 else { return 0 }
        return Double(slice.amountMinorUnits) / Double(largest)
    }

    // MARK: - Merchants

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
                    ForEach(Array(data.topMerchants.prefix(5).enumerated()), id: \.element.id) { index, merchant in
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
                        if index < min(data.topMerchants.count, 5) - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Categorization

    private var categorizeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Categorization")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.categorizationCounts.total > 0 {
                        NavigationLink {
                            InsightFilteredListView(
                                title: "Needs a Category",
                                emptyMessage: "Everything is categorized.",
                                currency: primaryCurrency,
                                scope: .needingCategory
                            )
                        } label: {
                            Label("Review", systemImage: "list.bullet")
                                .font(.caption.weight(.semibold))
                        }
                    }
                }

                statusLine

                Text("Rules and your past corrections run first, automatically after every sync and import. "
                    + "When available, Apple Intelligence’s on-device model works through the rest. "
                    + "Transaction text never leaves your device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !AppleIntelligenceCategorizer.isAvailable {
                    Text(AppleIntelligenceCategorizer.statusDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.categorizationState {
        case .running:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Categorizing automatically…")
                        .font(.callout)
                }
                if let progress = model.modelProgress, progress.total > 0 {
                    ProgressView(value: Double(progress.processed), total: Double(progress.total))
                    Text("\(progress.processed) of \(progress.total) checked with the on-device model")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case let .finished(categorized, counts):
            finishedStatus(categorized: categorized, counts: counts)
        case .idle:
            if model.categorizationCounts.total == 0 {
                allCategorizedLabel(categorized: 0)
            } else if automaticModelEnabled {
                Label(
                    "\(model.categorizationCounts.total) will be categorized automatically.",
                    systemImage: "clock"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                needsCategoryLabel(count: model.categorizationCounts.total)
            }
        }
    }

    @ViewBuilder
    private func finishedStatus(categorized: Int, counts: SyncEngine.CategorizationCounts) -> some View {
        if counts.total == 0 {
            allCategorizedLabel(categorized: categorized)
        } else if !AppleIntelligenceCategorizer.isAvailable {
            needsCategoryLabel(count: counts.total, reason: "Apple Intelligence isn’t available on this device.")
        } else if !model.useAppleIntelligence {
            needsCategoryLabel(count: counts.total, reason: "Apple Intelligence is turned off in Settings.")
        } else if counts.pendingModel > 0 {
            Label(
                "\(counts.pendingModel) still queued; they continue automatically next time.",
                systemImage: "clock"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            needsCategoryLabel(count: counts.unresolved, reason: "The on-device model couldn’t place them.")
        }
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

    private func needsCategoryLabel(count: Int, reason: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(
                "\(count) transaction\(count == 1 ? "" : "s") need a category.",
                systemImage: "exclamationmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if let reason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    private var automaticModelEnabled: Bool {
        model.useAppleIntelligence && AppleIntelligenceCategorizer.isAvailable
    }

    private func moneyText(_ minorUnits: Int64) -> String {
        Money(minorUnits: minorUnits, currency: primaryCurrency).formatted()
    }

    @ViewBuilder
    private func changePill(_ ratio: Double, higherIsBad: Bool) -> some View {
        let percent = Int((abs(ratio) * 100).rounded())
        let isUp = ratio >= 0
        let good = higherIsBad ? !isUp : isUp
        let color = percent == 0 ? CairnTheme.neutral : (good ? CairnTheme.positive : CairnTheme.negative)

        HStack(spacing: 2) {
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
