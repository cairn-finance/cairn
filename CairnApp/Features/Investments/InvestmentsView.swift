import SwiftUI
import SwiftData
import CairnCore

/// Investment accounts and their values as of the last sync.
///
/// SimpleFIN reports balances, not holdings or cost basis, so Cairn never shows
/// a live market price — only what each institution last told us.
struct InvestmentsView: View {
    @Query private var accounts: [Account]
    @Query private var settings: [AppSettings]

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

    /// The freshest balance date across the portfolio, used to make clear that
    /// these figures are a snapshot rather than a live quote.
    private var asOf: Date? {
        investments.compactMap { $0.balanceDate ?? $0.lastSyncedAt }.max()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                if investments.isEmpty {
                    EmptyStateView(
                        systemImage: "chart.line.uptrend.xyaxis",
                        title: "No investments yet",
                        message: "Accounts your bank reports as investments appear here after a sync."
                    )
                } else {
                    hero
                    accountsSection
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

        return HeroCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Invested")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }

                AmountText(
                    money: Money(minorUnits: totalMinorUnits, currency: currency),
                    font: .cairnHero,
                    colorOverride: .white,
                    deemphasizeFraction: true
                )

                HStack(spacing: 8) {
                    if let ratio = change.ratio {
                        TrendPill(ratio: ratio, higherIsBad: false, onInk: true)
                    }
                    Text(asOfText)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }

                if series.count > 2 {
                    Sparkline(
                        values: series.map { NetWorthMath.doubleValue($0.balanceMinorUnits, currency: currency) },
                        tint: CairnTheme.inkGlow,
                        lineWidth: 2
                    )
                    .frame(height: 56)
                }
            }
        }
        .cairnAppear()
    }

    private var asOfText: String {
        guard let asOf else { return "Waiting for the first sync" }
        return "Values as of \(asOf.formatted(.relative(presentation: .named)))"
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
            RowGroup {
                ForEach(Array(accounts.enumerated()), id: \.element.persistentModelID) { index, account in
                    NavigationLink {
                        AccountDetailView(account: account)
                    } label: {
                        AccountRow(account: account)
                    }
                    .buttonStyle(.plain)
                    if index < accounts.count - 1 { RowDivider() }
                }
            }
        }
    }

    // MARK: - Explainer

    private var aboutCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("How these numbers work")
                Text("Cairn shows the value your bank reported at the last sync. "
                    + "It does not fetch live market prices or track cost basis, so this is a snapshot — not a real-time portfolio value.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cairnAppear(delay: 0.1)
    }
}

/// A compact, tappable summary of investment accounts shown on Home. It exists
/// so Investments stays a focused pushed screen without adding a fifth tab.
struct InvestmentsSummaryRow: View {
    let accounts: [Account]
    let settings: [AppSettings]

    private var totals: [CurrencyTotal] { NetWorthMath.totals(accounts: accounts) }

    private var currency: Currency {
        NetWorthMath.primaryCurrency(totals: totals, home: NetWorthMath.homeCurrency(settings: settings))
    }

    private var total: Int64 {
        totals.first { $0.currency.code == currency.code }?.totalMinorUnits ?? 0
    }

    var body: some View {
        Card {
            HStack(spacing: CairnTheme.Spacing.m) {
                ZStack {
                    Circle()
                        .fill(CairnTheme.accent.opacity(0.14))
                        .frame(width: 42, height: 42)
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(CairnTheme.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Investments")
                        .font(.body.weight(.medium))
                    Text("\(accounts.count) account\(accounts.count == 1 ? "" : "s") · as of last sync")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: CairnTheme.Spacing.m)

                AmountText(
                    money: Money(minorUnits: total, currency: currency),
                    font: .body.weight(.semibold)
                )
                .fixedSize(horizontal: true, vertical: false)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
