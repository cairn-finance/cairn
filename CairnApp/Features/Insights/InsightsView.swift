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
    @State private var showAllCategories = false
    @State private var paceSelection: Int?
    @State private var trendSelection: Date?

    var body: some View {
        let data = snapshot
        return ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                monthPicker

                if currencyAccounts.isEmpty {
                    EmptyStateView(
                        systemImage: "chart.bar.xaxis",
                        title: "No accounts to analyze",
                        message: "Connect a bank or add an account to see spending insights."
                    )
                } else {
                    heroCard(data).cairnAppear()
                    paceCard(data).cairnAppear(delay: 0.05)
                    categoryCard(data).cairnAppear(delay: 0.1)
                    trendCard(data).cairnAppear(delay: 0.15)
                    merchantsCard(data).cairnAppear(delay: 0.2)
                    recurringCard.cairnAppear(delay: 0.24)
                    categorizeCard.cairnAppear(delay: 0.28)
                }
            }
            .cairnScreen()
        }
        .cairnCanvas()
        .navigationTitle("Insights")
        .task {
            await model.refreshCategorizationCounts()
            await model.refreshRecurring()
        }
        .onChange(of: month) { _, _ in
            paceSelection = nil
            trendSelection = nil
        }
        .sensoryFeedback(.selection, trigger: month)
    }

    // MARK: - Currency & data

    private var homeCurrency: Currency { NetWorthMath.homeCurrency(settings: settings) }

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
            historyMonths: InsightsCalculator.defaultHistoryMonths,
            now: .now
        )
    }

    private var insightTransactions: [InsightTransaction] {
        // Rows older than the snapshot's window cannot change any part of it, and
        // on a long ledger they are most of the store, so they are dropped before
        // a value is built for them.
        let earliest = InsightsCalculator.earliestUsedDate(month: month)
        return currencyAccounts.flatMap { account in
            (account.transactions ?? [])
                .filter { $0.effectiveDate >= earliest }
                .map { transaction in
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
        var months = (0..<12).reversed().compactMap {
            calendar.date(byAdding: .month, value: -$0, to: currentMonthStart)
        }
        if !months.contains(where: { calendar.isDate($0, equalTo: month, toGranularity: .month) }) {
            months.insert(calendar.dateInterval(of: .month, for: month)?.start ?? month, at: 0)
        }
        return months
    }

    private var monthPicker: some View {
        HStack(spacing: 8) {
            stepButton("chevron.left") { shiftMonth(-1) }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(recentMonths, id: \.self) { candidate in
                            Button {
                                withAnimation(CairnTheme.Motion.quick) { month = candidate }
                            } label: {
                                Chip(
                                    title: candidate.formatted(.dateTime.month(.abbreviated).year(.twoDigits)),
                                    isSelected: isSelected(candidate),
                                    tint: CairnTheme.ink
                                )
                            }
                            .buttonStyle(.plain)
                            .id(candidate)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.04),
                            .init(color: .black, location: 0.96),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .onAppear { scrollToSelected(proxy, animated: false) }
                .onChange(of: month) { _, _ in scrollToSelected(proxy, animated: true) }
            }

            stepButton("chevron.right") { shiftMonth(1) }
                .disabled(isCurrentMonth)
                .opacity(isCurrentMonth ? 0.3 : 1)
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(CairnTheme.surfaceInset, in: Circle())
                .overlay(Circle().strokeBorder(CairnTheme.outline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: month) else { return }
        guard next <= .now || Calendar.current.isDate(next, equalTo: .now, toGranularity: .month) else { return }
        withAnimation(CairnTheme.Motion.quick) { month = next }
    }

    private func scrollToSelected(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let selected = recentMonths.first(where: { isSelected($0) }) else { return }
        if animated {
            withAnimation(CairnTheme.Motion.quick) { proxy.scrollTo(selected, anchor: .center) }
        } else {
            proxy.scrollTo(selected, anchor: .center)
        }
    }

    // MARK: - Hero

    private func heroCard(_ data: InsightsSnapshot) -> some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(isCurrentMonth ? "Spent so far this month" : "Spent in \(data.monthStart.formatted(.dateTime.month(.wide)))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))

                AmountText(
                    money: Money(minorUnits: data.currentToDateSpending, currency: primaryCurrency),
                    font: .cairnHero,
                    colorOverride: .white,
                    deemphasizeFraction: true
                )

                HStack(spacing: 8) {
                    if let change = data.spendingChangeVsDate {
                        TrendPill(ratio: change, higherIsBad: true, onInk: true)
                        Text("vs this point last month")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    } else if isCurrentMonth {
                        Text("No comparison yet — last month had no spending.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                if isCurrentMonth, data.projectedSpending > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.needle")
                            .font(.caption.weight(.semibold))
                        Text("On pace for \(moneyText(data.projectedSpending)) by month end")
                            .font(.footnote.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.12), in: Capsule())
                }

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)

                HStack(alignment: .top, spacing: 16) {
                    heroMetric("Income", data.current.incomeMinorUnits)
                    heroMetric("Net", data.current.netMinorUnits, tint: data.current.netMinorUnits >= 0 ? CairnTheme.inkGlow : Color(red: 1, green: 0.62, blue: 0.58))
                    heroMetric("Avg / day", data.averageDailySpending())
                }
            }
        }
    }

    private func heroMetric(_ title: String, _ minorUnits: Int64, tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
            AmountText(
                money: Money(minorUnits: minorUnits, currency: primaryCurrency),
                font: .subheadline.weight(.semibold),
                colorOverride: tint
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pace

    private func idealPace(_ data: InsightsSnapshot) -> [PacePoint] {
        guard data.averageDailyPace > 0 else { return [] }
        return (1...data.daysInMonth).map { day in
            PacePoint(day: day, amountMinorUnits: data.averageDailyPace * Int64(day))
        }
    }

    /// The straight-line projection from the last real point to month end.
    private func projection(_ data: InsightsSnapshot) -> [PacePoint] {
        guard isCurrentMonth, let last = data.cumulative.last, last.day < data.daysInMonth else { return [] }
        return [last, PacePoint(day: data.daysInMonth, amountMinorUnits: data.projectedSpending)]
    }

    private func paceCard(_ data: InsightsSnapshot) -> some View {
        let selected = paceSelection.flatMap { day in data.cumulative.first { $0.day == day } }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    "Spending pace",
                    subtitle: selected.map { "Day \($0.day): \(moneyText($0.amountMinorUnits)) spent" } ?? paceSubtitle(data)
                )

                if data.cumulative.isEmpty {
                    Text("No spending recorded yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Chart {
                        ForEach(data.cumulative) { point in
                            AreaMark(
                                x: .value("Day", point.day),
                                y: .value("Spent", dollars(point.amountMinorUnits)),
                                series: .value("Series", "actual")
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [CairnTheme.accent.opacity(0.28), CairnTheme.accent.opacity(0.0)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.monotone)
                            LineMark(
                                x: .value("Day", point.day),
                                y: .value("Spent", dollars(point.amountMinorUnits)),
                                series: .value("Series", "actual")
                            )
                            .foregroundStyle(CairnTheme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                            .interpolationMethod(.monotone)
                        }
                        ForEach(projection(data)) { point in
                            LineMark(
                                x: .value("Day", point.day),
                                y: .value("Spent", dollars(point.amountMinorUnits)),
                                series: .value("Series", "projection")
                            )
                            .foregroundStyle(CairnTheme.accent.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [2, 4]))
                        }
                        ForEach(idealPace(data)) { point in
                            LineMark(
                                x: .value("Day", point.day),
                                y: .value("Spent", dollars(point.amountMinorUnits)),
                                series: .value("Series", "usual")
                            )
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                        }
                        if isCurrentMonth, let last = data.cumulative.last {
                            PointMark(
                                x: .value("Day", last.day),
                                y: .value("Spent", dollars(last.amountMinorUnits))
                            )
                            .symbolSize(70)
                            .foregroundStyle(CairnTheme.accent)
                        }
                        if let selected {
                            RuleMark(x: .value("Selected", selected.day))
                                .foregroundStyle(Color.secondary.opacity(0.4))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            PointMark(
                                x: .value("Selected", selected.day),
                                y: .value("Spent", dollars(selected.amountMinorUnits))
                            )
                            .symbolSize(70)
                            .foregroundStyle(CairnTheme.accent)
                        }
                    }
                    .chartXScale(domain: 1...data.daysInMonth)
                    .chartXSelection(value: $paceSelection)
                    .chartXAxis {
                        AxisMarks(values: [1, 8, 15, 22, data.daysInMonth]) { value in
                            AxisValueLabel {
                                if let day = value.as(Int.self) { Text("\(day)").foregroundStyle(Color.secondary) }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(CairnTheme.hairline)
                            AxisValueLabel {
                                if let amount = value.as(Double.self) { Text(shortCurrency(amount)).foregroundStyle(Color.secondary) }
                            }
                        }
                    }
                    .frame(height: 180)
                    .sensoryFeedback(.selection, trigger: paceSelection)

                    HStack(spacing: 14) {
                        legend("This month", color: CairnTheme.accent, dashed: false)
                        if isCurrentMonth {
                            legend("Projected", color: CairnTheme.accent.opacity(0.55), dashed: true)
                        }
                        if data.averageDailyPace > 0 {
                            legend("Usual pace", color: .secondary, dashed: true)
                        }
                    }
                }
            }
        }
    }

    private func paceSubtitle(_ data: InsightsSnapshot) -> String? {
        guard isCurrentMonth, data.averageDailyPace > 0 else { return nil }
        let usual = data.averageDailyPace * Int64(data.lastDayWithData)
        let diff = data.currentToDateSpending - usual
        if abs(diff) < max(100, usual / 50) { return "Right on your usual pace." }
        return diff > 0
            ? "\(moneyText(diff)) ahead of your usual pace."
            : "\(moneyText(-diff)) under your usual pace."
    }

    private func legend(_ title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(color)
                .frame(width: 14, height: 2)
                .mask {
                    if dashed {
                        HStack(spacing: 2) {
                            Rectangle(); Rectangle(); Rectangle()
                        }
                    } else {
                        Rectangle()
                    }
                }
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Trend

    private func trendCard(_ data: InsightsSnapshot) -> some View {
        let average = data.months.isEmpty ? 0 : data.months.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.spendingMinorUnits) } / Int64(data.months.count)
        let selected = trendSelection.flatMap { date in
            data.months.first { Calendar.current.isDate($0.monthStart, equalTo: date, toGranularity: .month) }
        }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    "Six-month trend",
                    subtitle: selected.map {
                        "\($0.monthStart.formatted(.dateTime.month(.wide))): \(moneyText($0.spendingMinorUnits)) spent"
                    } ?? "Average \(moneyText(average)) per month"
                )

                Chart(data.months) { totals in
                    BarMark(
                        x: .value("Month", totals.monthStart, unit: .month),
                        y: .value("Spending", dollars(totals.spendingMinorUnits)),
                        width: .ratio(0.55)
                    )
                    .foregroundStyle(
                        isSelected(totals.monthStart)
                            ? AnyShapeStyle(CairnTheme.inkGradient)
                            : AnyShapeStyle(CairnTheme.accent.opacity(0.28))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    RuleMark(y: .value("Average", dollars(average)))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    if let selected {
                        RuleMark(x: .value("Selected", selected.monthStart, unit: .month))
                            .foregroundStyle(Color.secondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartXSelection(value: $trendSelection)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(CairnTheme.hairline)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) { Text(shortCurrency(amount)).foregroundStyle(Color.secondary) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.narrow))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .frame(height: 150)
                .sensoryFeedback(.selection, trigger: trendSelection)
            }
        }
    }

    // MARK: - Categories

    private func categoryCard(_ data: InsightsSnapshot) -> some View {
        let visible = showAllCategories ? data.categories : Array(data.categories.prefix(6))
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("By category") {
                    if data.categories.count > 6 {
                        Button(showAllCategories ? "Show less" : "Show all") {
                            withAnimation(CairnTheme.Motion.standard) { showAllCategories.toggle() }
                        }
                        .font(.subheadline.weight(.medium))
                    }
                }

                if data.categories.isEmpty {
                    Text("No spending recorded this month.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(visible) { slice in
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
    }

    private func categoryRow(_ slice: CategoryBreakdown, in data: InsightsSnapshot) -> some View {
        let total = data.categories.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.amountMinorUnits) }
        let share = total > 0 ? Double(slice.amountMinorUnits) / Double(total) : 0
        let tint = CairnTheme.color(hex: slice.colorHex)
        let fraction = fraction(slice, in: data)

        return HStack(spacing: 12) {
            CategoryBadge(symbolName: symbol(for: slice.name), hex: slice.colorHex, size: 34)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(slice.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if data.topMoverNames.contains(slice.name), let change = slice.changeRatio {
                        TrendPill(ratio: change, higherIsBad: true)
                    }
                    Spacer(minLength: 8)
                    AmountText(
                        money: Money(minorUnits: slice.amountMinorUnits, currency: primaryCurrency),
                        font: .subheadline.weight(.semibold)
                    )
                }
                HStack(spacing: 8) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(tint.opacity(0.12))
                            Capsule()
                                .fill(tint)
                                .frame(width: max(4, proxy.size.width * fraction))
                        }
                    }
                    .frame(height: 5)
                    Text(share.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    /// Insights only carries the category name; look the symbol up so rows
    /// match the transaction list.
    private func symbol(for categoryName: String) -> String? {
        for account in currencyAccounts {
            for transaction in account.transactions ?? [] {
                if let category = transaction.effectiveCategory, category.name == categoryName {
                    return category.symbolName
                }
            }
        }
        return categoryName == InsightsCalculator.uncategorizedName ? "questionmark.circle" : nil
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
                CardHeader("Top merchants")

                if data.topMerchants.isEmpty {
                    Text("No merchants yet this month.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(data.topMerchants.prefix(5).enumerated()), id: \.element.id) { index, merchant in
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.caption.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(index == 0 ? Color.white : .secondary)
                                    .frame(width: 24, height: 24)
                                    .background(index == 0 ? AnyShapeStyle(CairnTheme.inkGradient) : AnyShapeStyle(CairnTheme.surfaceInset), in: Circle())
                                Text(merchant.name.capitalized)
                                    .font(.callout.weight(index == 0 ? .semibold : .regular))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                AmountText(
                                    money: Money(minorUnits: merchant.amountMinorUnits, currency: primaryCurrency),
                                    font: .callout.weight(.medium)
                                )
                            }
                            .padding(.vertical, 8)
                            if index < min(data.topMerchants.count, 5) - 1 {
                                RowDivider(leadingInset: 36)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recurring

    private var recurringCard: some View {
        let currencySeries = model.recurringSeries.filter { $0.currency.code == primaryCurrency.code }
        return NavigationLink {
            RecurringView()
        } label: {
            RecurringSummaryCard(series: currencySeries, currency: primaryCurrency)
        }
        .buttonStyle(.pressableCard)
    }

    // MARK: - Categorization

    private var categorizeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    SettingsIcon(systemImage: "sparkles", tint: Color(red: 0.62, green: 0.36, blue: 0.87))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic categorization")
                            .font(.headline)
                        Text("On-device. Transaction text never leaves this device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 14) {
                        NavigationLink {
                            RulesView()
                        } label: {
                            Text("Rules")
                                .font(.subheadline.weight(.semibold))
                        }
                        if model.categorizationCounts.total > 0 {
                            NavigationLink {
                                InsightFilteredListView(
                                    title: "Needs a Category",
                                    emptyMessage: "Everything is categorized.",
                                    currency: primaryCurrency,
                                    scope: .needingCategory
                                )
                            } label: {
                                Text("Review")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                }

                statusLine

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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Categorizing…")
                        .font(.callout)
                }
                if let progress = model.modelProgress, progress.total > 0 {
                    ProgressView(value: Double(progress.processed), total: Double(progress.total))
                        .tint(CairnTheme.accent)
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
                statusLabel("\(model.categorizationCounts.total) will be categorized automatically.", systemImage: "clock", tint: .secondary)
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
            statusLabel(pendingModelMessage(counts.pendingModel), systemImage: "clock", tint: .secondary)
        } else {
            needsCategoryLabel(count: counts.unresolved, reason: "The on-device model couldn’t place them.")
        }
    }

    /// Explains *why* work is still queued, so a pass paused for power doesn't
    /// look stuck.
    private func pendingModelMessage(_ count: Int) -> String {
        switch model.modelPauseReason {
        case .pauseBattery:
            "\(count) still queued; they finish while your device is charging."
        case .pauseLowPower:
            "\(count) still queued; they continue when Low Power Mode is off."
        case .pauseThermal:
            "\(count) still queued; they continue once your device cools down."
        default:
            "\(count) still queued; they continue automatically next time."
        }
    }

    private func statusLabel(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tint)
    }

    private func allCategorizedLabel(categorized: Int) -> some View {
        statusLabel(
            categorized > 0
                ? "Categorized \(categorized) transaction\(categorized == 1 ? "" : "s"). All caught up."
                : "All transactions are categorized.",
            systemImage: "checkmark.circle.fill",
            tint: CairnTheme.positive
        )
    }

    private func needsCategoryLabel(count: Int, reason: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            statusLabel(
                "\(count) transaction\(count == 1 ? "" : "s") need a category.",
                systemImage: "exclamationmark.circle",
                tint: .secondary
            )
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

    private func dollars(_ minorUnits: Int64) -> Double {
        NetWorthMath.doubleValue(minorUnits, currency: primaryCurrency)
    }

    private func shortCurrency(_ value: Double) -> String {
        Money(minorUnits: Int64(value * pow(10, Double(primaryCurrency.exponent))), currency: primaryCurrency).compactFormatted()
    }
}
