import SwiftUI
import SwiftData
import CairnCore

/// Investment accounts, their positions, and the values the bank last reported.
///
/// SimpleFIN reports positions (symbol, shares, market value, cost basis) at the
/// last sync, so Cairn can show what you hold and the gain since purchase — but
/// it never fetches a live market price.
struct InvestmentsView: View {
    @Query private var accounts: [Account]
    @Query private var settings: [AppSettings]

    @State private var selectedIndex: Int?

    private var investments: [Account] {
        accounts.filter { !$0.isHidden && $0.accountType == .investment }
    }

    private var totals: [CurrencyTotal] { NetWorthMath.totals(accounts: investments) }

    private var currency: Currency {
        NetWorthMath.primaryCurrency(totals: totals, home: NetWorthMath.homeCurrency(settings: settings))
    }

    private var totalMinorUnits: Int64 {
        totals.first { $0.currency.code == currency.code }?.totalMinorUnits ?? 0
    }

    private var series: [(date: Date, balanceMinorUnits: Int64)] {
        NetWorthMath.series(accounts: investments, currency: currency, days: 90)
    }

    private var selectedPoint: (date: Date, balanceMinorUnits: Int64)? {
        guard let selectedIndex, series.indices.contains(selectedIndex) else { return nil }
        return series[selectedIndex]
    }

    /// The freshest balance date across the portfolio, used to make clear that
    /// these figures are a snapshot rather than a live quote.
    private var asOf: Date? {
        investments.compactMap { $0.balanceDate ?? $0.lastSyncedAt }.max()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                if investments.isEmpty {
                    GetStartedEmptyState(
                        systemImage: "chart.line.uptrend.xyaxis",
                        title: "No investments yet",
                        message: "Accounts your bank reports as investments appear here after a sync. "
                            + "You can also add one by hand and import a CSV.",
                        manualAccountType: .investment
                    )
                } else {
                    hero
                    accountsSection
                    if investments.allSatisfy({ ($0.holdings ?? []).isEmpty }) {
                        holdingsEmptyNote
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
    }

    // MARK: - Hero

    private var hero: some View {
        let change = NetWorthMath.change(in: series)
        let shown = selectedPoint?.balanceMinorUnits ?? totalMinorUnits

        return HeroCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(selectedPoint.map { $0.date.formatted(date: .abbreviated, time: .omitted) } ?? "Invested")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.opacity)
                    Spacer()
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
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
            }
        }
        .cairnAppear()
        .animation(CairnTheme.Motion.quick, value: selectedIndex)
    }

    private var asOfText: String {
        guard let asOf else { return "Waiting for the first sync" }
        return "Values as of \(asOf.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        let grouped = Dictionary(grouping: investments) { $0.institution?.name ?? "Manual" }
        return VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
            ForEach(grouped.keys.sorted(), id: \.self) { name in
                if let group = grouped[name] {
                    accountGroup(title: name.isEmpty ? "Institution" : name, accounts: group)
                }
            }
        }
        .cairnAppear(delay: 0.05)
    }

    private func accountGroup(title: String, accounts: [Account]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title, trailing: "\(accounts.count)")
            VStack(spacing: 12) {
                ForEach(accounts, id: \.persistentModelID) { account in
                    accountCard(account)
                }
            }
        }
    }

    private func accountCard(_ account: Account) -> some View {
        let holdings = (account.holdings ?? []).sorted { $0.displayOrder < $1.displayOrder }
        return RowGroup {
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

    private var aboutCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("How these numbers work")
                Text("Cairn shows the positions and value your bank reported at the last sync. "
                    + "It does not fetch live market prices, so these figures are a snapshot — not a real-time portfolio value.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cairnAppear(delay: 0.1)
    }
}
