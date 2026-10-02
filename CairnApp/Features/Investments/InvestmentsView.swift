import SwiftUI
import SwiftData
import Charts
import CairnCore

/// Investment accounts, their positions, and the values the bank last reported.
///
/// SimpleFIN reports positions (symbol, shares, market value, cost basis) at the
/// last sync, so Cairn can show what you hold and the gain since purchase — but
/// it never fetches a live market price.
struct InvestmentsView: View {
    @Query private var accounts: [Account]
    @Query private var settings: [AppSettings]
    @Query private var chartTransactions: [LedgerTransaction]

    @State private var selectedIndex: Int?
    @State private var historyRange: HistoryRange = .ninetyDays
    @State private var searchText = ""
    @State private var sortOption: HoldingSortOption = .value
    @State private var selectedMixCurrencyID: String?

    init() {
        _chartTransactions = Query(filter: NetWorthMath.transactionPredicate(days: 365))
    }

    private var investments: [Account] {
        accounts.filter { !$0.isHidden && $0.accountType == .investment }
    }

    private var investmentHoldings: [Holding] {
        investments.flatMap { $0.holdings ?? [] }
    }

    private var portfolioSummaries: [InvestmentCurrencySummary] {
        InvestmentPortfolioSummary.byCurrency(holdings: investmentHoldings)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredInvestments: [Account] {
        investments.filter { account in
            accountMatchesSearch(account) ||
                (account.holdings ?? []).contains { holdingMatchesSearch($0) }
        }
    }

    private var totals: [CurrencyTotal] { NetWorthMath.totals(accounts: investments) }

    private var currency: Currency {
        NetWorthMath.primaryCurrency(totals: totals, home: NetWorthMath.homeCurrency(settings: settings))
    }

    private var totalMinorUnits: Int64 {
        totals.first { $0.currency == currency }?.totalMinorUnits ?? 0
    }

    private var series: [(date: Date, balanceMinorUnits: Int64)] {
        NetWorthMath.series(accounts: investments, currency: currency, transactions: chartTransactions, days: historyRange.days)
    }

    private var selectedPoint: (date: Date, balanceMinorUnits: Int64)? {
        guard let selectedIndex, series.indices.contains(selectedIndex) else { return nil }
        return series[selectedIndex]
    }

    /// The latest date reported by any investment account. Each account also
    /// shows its own update date below.
    private var asOf: Date? {
        investments.compactMap { $0.balanceDate ?? $0.lastSyncedAt }.max()
    }

    private var mixCurrency: Currency? {
        if let selectedMixCurrencyID,
           let selected = portfolioSummaries.first(where: { $0.id == selectedMixCurrencyID }) {
            return selected.currency
        }
        let home = NetWorthMath.homeCurrency(settings: settings)
        return portfolioSummaries.first(where: { $0.currency == home })?.currency
            ?? portfolioSummaries.first(where: { $0.currency.code == home.code })?.currency
            ?? portfolioSummaries.first?.currency
    }

    private var mixPositions: [InvestmentPositionMix] {
        guard let mixCurrency else { return [] }
        return InvestmentPortfolioSummary.positionMix(holdings: investmentHoldings, currency: mixCurrency)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                if investments.isEmpty {
                    GetStartedEmptyState(
                        systemImage: "chart.line.uptrend.xyaxis",
                        title: "No investments yet",
                        message: "Accounts your bank reports as investments appear here after a sync.",
                        manualAccountType: .investment
                    )
                } else {
                    hero
                    if !investmentHoldings.isEmpty {
                        portfolioSummary
                        positionMixCard
                    }
                    if normalizedSearchText.isEmpty && investmentHoldings.isEmpty {
                        holdingsEmptyNote
                    }
                    if !normalizedSearchText.isEmpty && filteredInvestments.isEmpty {
                        noSearchResults
                    } else {
                        accountsSection
                    }
                    aboutCard
                }
            }
            .cairnScreen()
        }
        .cairnCanvas()
        .navigationTitle("Investments")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $searchText, prompt: "Ticker, holding, or account")
        .onChange(of: historyRange) { _, _ in selectedIndex = nil }
        .onChange(of: portfolioSummaries.map(\.id)) { _, identifiers in
            if let selectedMixCurrencyID, !identifiers.contains(selectedMixCurrencyID) {
                self.selectedMixCurrencyID = nil
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        let change = NetWorthMath.change(in: series)
        let shown = selectedPoint?.balanceMinorUnits ?? totalMinorUnits

        return HeroCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    if let selectedPoint {
                        Text(selectedPoint.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .contentTransition(.opacity)
                    } else {
                        Text("Account balance")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .contentTransition(.opacity)
                    }
                    Spacer()
                    SegmentedPicker(options: HistoryRange.allCases, selection: $historyRange) {
                        LocalizedStringKey($0.title)
                    }
                    .frame(maxWidth: 180)
                }

                AmountText(
                    money: Money(minorUnits: shown, currency: currency),
                    font: .cairnHero,
                    colorOverride: .white,
                    deemphasizeFraction: true
                )

                HStack(spacing: 8) {
                    if let selected = selectedPoint {
                        Text("Balance on \(selected.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        if let ratio = change.ratio {
                            TrendPill(ratio: ratio, higherIsBad: false, onInk: true)
                        }
                        Text(asOfText)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                if series.count > 2 {
                    Sparkline(
                        values: series.map { NetWorthMath.doubleValue($0.balanceMinorUnits, currency: currency) },
                        tint: CairnTheme.inkGlow,
                        lineWidth: 2,
                        selection: $selectedIndex
                    )
                    .frame(height: 56)
                    .onChange(of: series.count) { _, _ in selectedIndex = nil }
                    .sensoryFeedback(.selection, trigger: selectedIndex)
                }

                Text("Transaction-derived account balance history, not investment performance.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .cairnAppear()
        .animation(CairnTheme.Motion.quick, value: selectedIndex)
    }

    private var asOfText: LocalizedStringKey {
        guard let asOf else { return "Waiting for the first sync" }
        return "Latest account update: \(asOf.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        let grouped = Dictionary(grouping: filteredInvestments) { $0.institution?.name ?? "Manual" }
        return VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
            HStack {
                Text("Accounts and positions")
                    .font(.cairnLabel)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("Sort holdings", selection: $sortOption) {
                        ForEach(HoldingSortOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.medium))
                }
            }

            ForEach(grouped.keys.sorted(), id: \.self) { name in
                if let group = grouped[name] {
                    accountGroup(title: name.isEmpty ? "Institution" : LocalizedStringKey(name), accounts: group)
                }
            }
        }
        .cairnAppear(delay: 0.05)
    }

    private func accountGroup(title: LocalizedStringKey, accounts: [Account]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title, trailing: "\(accounts.count)")
            VStack(spacing: 12) {
                ForEach(accounts.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }, id: \.persistentModelID) { account in
                    accountCard(account)
                }
            }
        }
    }

    private func accountCard(_ account: Account) -> some View {
        let holdings = visibleHoldings(for: account)
        return VStack(alignment: .leading, spacing: 4) {
            RowGroup {
                NavigationLink {
                    AccountDetailView(account: account)
                } label: {
                    AccountRow(account: account)
                }
                .buttonStyle(.plain)

                ForEach(holdings, id: \.persistentModelID) { holding in
                    RowDivider()
                    HoldingRow(holding: holding)
                }
            }

            accountFreshness(account)
        }
    }

    private func accountFreshness(_ account: Account) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "clock")
                .accessibilityHidden(true)
            if let date = account.balanceDate {
                Text("Balance as of \(date.formatted(date: .abbreviated, time: .shortened))")
            } else if let date = account.lastSyncedAt {
                Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))")
            } else if account.isManual {
                Text("Manual account · no sync date")
            } else {
                Text("Waiting for the first sync")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
    }

    // MARK: - Reported position summaries

    private var portfolioSummary: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader("Reported positions")
                ForEach(Array(portfolioSummaries.enumerated()), id: \.element.id) { index, summary in
                    if index > 0 {
                        Divider()
                    }
                    currencySummary(summary)
                }
            }
        }
        .cairnAppear(delay: 0.03)
    }

    private func currencySummary(_ summary: InvestmentCurrencySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.currency.displayLabel)
                        .font(.subheadline.weight(.semibold))
                    Text("\(summary.positionCount) positions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                AmountText(
                    money: Money(minorUnits: summary.positionValueMinorUnits, currency: summary.currency),
                    font: .body.weight(.semibold)
                )
            }

            HStack(alignment: .top, spacing: CairnTheme.Spacing.l) {
                summaryMetric(
                    title: "Cost basis",
                    minorUnits: summary.costBasisMinorUnits,
                    currency: summary.currency
                )
                Spacer(minLength: 0)
                summaryMetric(
                    title: "Unrealized gain/loss",
                    minorUnits: summary.unrealizedGainMinorUnits,
                    currency: summary.currency,
                    isGain: true
                )
            }

            if summary.hasPartialCostBasis {
                Text("Cost basis reported for \(summary.costBasisPositionCount) of \(summary.positionCount) positions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if summary.hasCompleteCostBasis {
                Text("Cost basis reported for all \(summary.positionCount) positions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No cost basis reported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summaryMetric(
        title: LocalizedStringKey,
        minorUnits: Int64?,
        currency: Currency,
        isGain: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let minorUnits {
                AmountText(
                    money: Money(minorUnits: minorUnits, currency: currency),
                    font: .subheadline.weight(.semibold),
                    colorOverride: isGain ? (minorUnits < 0 ? CairnTheme.negative : CairnTheme.positive) : nil
                )
            } else {
                Text("Not reported")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Position mix

    private var positionMixCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardHeader("Position mix")
                    Spacer()
                    if let mixCurrency {
                        if portfolioSummaries.count > 1 {
                            Menu {
                                Picker("Currency", selection: Binding(
                                    get: { mixCurrency.stableIdentifier },
                                    set: { selectedMixCurrencyID = $0 }
                                )) {
                                    ForEach(portfolioSummaries) { summary in
                                        Text(summary.currency.displayLabel).tag(summary.id)
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(mixCurrency.displayLabel)
                                    Image(systemName: "chevron.down")
                                        .font(.caption2.weight(.semibold))
                                }
                                .font(.subheadline.weight(.medium))
                            }
                        } else {
                            Text(mixCurrency.displayLabel)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if mixPositions.isEmpty {
                    Text("No positive position values to chart.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    positionMixChart
                    positionMixLegend
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Holdings by reported value, not sector allocation. Smaller positions are grouped as Other.")
                    Text("Positive values only. Position totals may not reconcile to account balances.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cairnAppear(delay: 0.06)
    }

    @ViewBuilder
    private var positionMixChart: some View {
        if let mixCurrency {
            Chart(Array(mixPositions.enumerated()), id: \.element.id) { index, position in
                SectorMark(
                    angle: .value("Reported position value", position.valueMinorUnits),
                    innerRadius: .ratio(0.66),
                    angularInset: 1
                )
                .foregroundStyle(positionMixColors[index % positionMixColors.count])
                .accessibilityLabel(Text(verbatim: mixLabel(position)))
                .accessibilityValue(Text(verbatim: Money(
                    minorUnits: position.valueMinorUnits,
                    currency: mixCurrency
                ).formatted()))
            }
            .chartLegend(.hidden)
            .frame(height: 175)
            .accessibilityLabel(Text("Investment position mix"))
        }
    }

    private var positionMixLegend: some View {
        VStack(spacing: 8) {
            ForEach(Array(mixPositions.enumerated()), id: \.element.id) { index, position in
                HStack(spacing: 8) {
                    Circle()
                        .fill(positionMixColors[index % positionMixColors.count])
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(mixLabel(position))
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let mixCurrency {
                        AmountText(
                            money: Money(minorUnits: position.valueMinorUnits, currency: mixCurrency),
                            font: .caption.weight(.medium)
                        )
                    }
                }
            }
        }
    }

    private var positionMixColors: [Color] {
        [CairnTheme.accent, CairnTheme.positive, CairnTheme.inkGlow, CairnTheme.warning, CairnTheme.negative, .purple]
    }

    private func mixLabel(_ position: InvestmentPositionMix) -> String {
        position.isOther ? String(localized: "Other") : position.label
    }

    // MARK: - Search and sorting

    private func accountMatchesSearch(_ account: Account) -> Bool {
        guard !normalizedSearchText.isEmpty else { return true }
        return account.displayName.localizedCaseInsensitiveContains(normalizedSearchText)
            || account.name.localizedCaseInsensitiveContains(normalizedSearchText)
            || (account.institution?.name.localizedCaseInsensitiveContains(normalizedSearchText) ?? false)
    }

    private func holdingMatchesSearch(_ holding: Holding) -> Bool {
        guard !normalizedSearchText.isEmpty else { return true }
        return holding.displayLabel.localizedCaseInsensitiveContains(normalizedSearchText)
            || holding.name.localizedCaseInsensitiveContains(normalizedSearchText)
            || (holding.symbol?.localizedCaseInsensitiveContains(normalizedSearchText) ?? false)
    }

    private func visibleHoldings(for account: Account) -> [Holding] {
        let holdings = account.holdings ?? []
        let matching = normalizedSearchText.isEmpty || accountMatchesSearch(account)
            ? holdings
            : holdings.filter(holdingMatchesSearch)
        return matching.sorted(by: holdingSortsBefore)
    }

    private func holdingSortsBefore(_ lhs: Holding, _ rhs: Holding) -> Bool {
        switch sortOption {
        case .value:
            if lhs.marketValueMinorUnits != rhs.marketValueMinorUnits {
                return lhs.marketValueMinorUnits > rhs.marketValueMinorUnits
            }
        case .gain:
            switch (lhs.gain?.minorUnits, rhs.gain?.minorUnits) {
            case let (left?, right?) where left != right:
                return left > right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }
        case .name:
            let comparison = lhs.displayLabel.localizedStandardCompare(rhs.displayLabel)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        }
        return lhs.displayLabel.localizedStandardCompare(rhs.displayLabel) == .orderedAscending
    }

    // MARK: - Explainer

    private var holdingsEmptyNote: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("No positions yet")
                Text("Your bank hasn’t reported any holdings for these accounts. Positions usually arrive with the next sync.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cairnAppear(delay: 0.07)
    }

    private var noSearchResults: some View {
        EmptyStateView(
            systemImage: "magnifyingglass",
            title: "No matching positions",
            message: "Try another ticker, holding, or account name."
        )
    }

    private var aboutCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("How these numbers work")
                Text("Balances and positions reflect your bank’s last report. Cairn does not fetch live prices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Position totals may not reconcile to account balances.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cairnAppear(delay: 0.1)
    }
}

private enum HistoryRange: String, CaseIterable, Identifiable {
    case thirtyDays
    case ninetyDays
    case sixMonths
    case oneYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thirtyDays: "1M"
        case .ninetyDays: "3M"
        case .sixMonths: "6M"
        case .oneYear: "1Y"
        }
    }

    var days: Int {
        switch self {
        case .thirtyDays: 30
        case .ninetyDays: 90
        case .sixMonths: 182
        case .oneYear: 365
        }
    }
}

private enum HoldingSortOption: String, CaseIterable, Identifiable {
    case value
    case gain
    case name

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .value: "Value"
        case .gain: "Gain/loss"
        case .name: "Name or ticker"
        }
    }
}
