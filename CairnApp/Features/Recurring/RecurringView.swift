import SwiftUI
import SwiftData
import CairnCore

/// Subscriptions and other regular payments Cairn has spotted in history.
/// Detection is entirely on-device; nothing about a merchant leaves the phone.
struct RecurringView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Account> { $0.isHidden == false })
    private var accounts: [Account]
    @Query private var settings: [AppSettings]

    private var homeCurrency: Currency { NetWorthMath.homeCurrency(settings: settings) }

    private var primaryCurrency: Currency {
        if accounts.contains(where: { $0.currency.code == homeCurrency.code }) {
            return homeCurrency
        }
        return accounts.first?.currency ?? homeCurrency
    }

    private var series: [RecurringSeries] {
        model.recurringSeries.filter { $0.currency.code == primaryCurrency.code }
    }

    private var outgoing: [RecurringSeries] {
        series.filter { $0.direction == .outgoing }
    }

    private var incoming: [RecurringSeries] {
        series.filter { $0.direction == .incoming }
    }

    private var monthlyOutgoing: Int64 {
        outgoing.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.monthlyEquivalentMinorUnits) }
    }

    private var monthlyIncoming: Int64 {
        incoming.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.monthlyEquivalentMinorUnits) }
    }

    /// The soonest upcoming charge, used for the hero's secondary line.
    private var nextCharge: RecurringSeries? {
        outgoing
            .filter { !$0.isOverdue() }
            .min { $0.nextExpectedDate < $1.nextExpectedDate }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                if series.isEmpty {
                    EmptyStateView(
                        systemImage: "repeat",
                        title: "No recurring payments yet",
                        message: "Cairn looks for charges that repeat on a regular schedule. It needs at least "
                            + "three similar charges on the same account before it calls something recurring."
                    )
                } else {
                    hero.cairnAppear()
                    if !outgoing.isEmpty {
                        section("Subscriptions & bills", series: outgoing).cairnAppear(delay: 0.05)
                    }
                    if !incoming.isEmpty {
                        section("Recurring income", series: incoming).cairnAppear(delay: 0.1)
                    }
                    FootnoteText(
                        "Based on your synced and imported history. Cairn never sends merchant names off this device."
                    )
                    .cairnAppear(delay: 0.15)
                }
            }
            .cairnScreen()
        }
        .cairnCanvas()
        .navigationTitle("Recurring")
        .task { await model.refreshRecurring() }
    }

    // MARK: - Hero

    private var hero: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Recurring commitments")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))

                AmountText(
                    money: Money(minorUnits: monthlyOutgoing, currency: primaryCurrency),
                    font: .cairnHero,
                    colorOverride: .white,
                    deemphasizeFraction: true
                )

                HStack(spacing: 8) {
                    Text("\(outgoing.count) subscription\(outgoing.count == 1 ? "" : "s") & bills")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                    if let next = nextCharge {
                        Text("·")
                            .foregroundStyle(.white.opacity(0.4))
                        Text("Next \(next.nextExpectedDate.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                if !incoming.isEmpty {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 1)
                    HStack(alignment: .top, spacing: 16) {
                        heroMetric("Monthly out", monthlyOutgoing)
                        heroMetric("Monthly in", monthlyIncoming, tint: CairnTheme.inkGlow)
                    }
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

    // MARK: - Sections

    private func section(_ title: String, series: [RecurringSeries]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title)
            RowGroup {
                ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                    NavigationLink {
                        RecurringDetailView(series: item)
                    } label: {
                        RecurringRow(series: item)
                    }
                    .buttonStyle(.plain)
                    if index < series.count - 1 {
                        RowDivider()
                    }
                }
            }
        }
    }
}

/// One detected series in the list: the merchant, its rhythm, and the charge.
struct RecurringRow: View {
    let series: RecurringSeries

    var body: some View {
        HStack(spacing: CairnTheme.Spacing.m) {
            CategoryBadge(
                symbolName: series.categorySymbolName ?? "repeat",
                hex: series.categoryColorHex,
                size: 40
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(series.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(series.cadence.displayName)
                    Text("·").foregroundStyle(.tertiary)
                    Text(nextText.text)
                        .foregroundStyle(nextText.isOverdue ? CairnTheme.warning : .secondary)
                    if let label = series.confidenceLabel {
                        StatusPill(text: label, tint: .secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                AmountText(
                    money: Money(minorUnits: abs(series.averageAmountMinorUnits), currency: series.currency),
                    showSign: series.direction == .incoming,
                    font: .body.weight(.semibold),
                    colorOverride: series.direction == .incoming ? CairnTheme.positive : nil
                )
                .fixedSize(horizontal: true, vertical: false)

                if series.cadence != .monthly {
                    Text("≈ \(Money(minorUnits: series.monthlyEquivalentMinorUnits, currency: series.currency).formatted())/mo")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    private var nextText: (text: String, isOverdue: Bool) {
        let days = series.daysUntilNext()
        if days < 0 {
            return ("Was due \(series.nextExpectedDate.formatted(.dateTime.month(.abbreviated).day()))", true)
        }
        if days == 0 {
            return ("Due today", false)
        }
        if days <= 7 {
            return ("Due in \(days) day\(days == 1 ? "" : "s")", false)
        }
        return ("Next \(series.nextExpectedDate.formatted(.dateTime.month(.abbreviated).day()))", false)
    }
}

/// A compact entry point shown on Home and Insights.
struct RecurringSummaryCard: View {
    let series: [RecurringSeries]
    let currency: Currency

    private var outgoing: [RecurringSeries] {
        series.filter { $0.direction == .outgoing }
    }

    private var monthlyOutgoing: Int64 {
        outgoing.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.monthlyEquivalentMinorUnits) }
    }

    var body: some View {
        Card {
            HStack(spacing: 12) {
                SettingsIcon(systemImage: "repeat", tint: Color(red: 0.62, green: 0.36, blue: 0.87))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subscriptions & recurring")
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if monthlyOutgoing > 0 {
                    AmountText(
                        money: Money(minorUnits: monthlyOutgoing, currency: currency),
                        font: .subheadline.weight(.semibold)
                    )
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var subtitle: String {
        guard !series.isEmpty else { return "None detected yet" }
        let subscriptions = series.filter(\.isSubscription).count
        return "\(series.count) detected · \(subscriptions) subscription\(subscriptions == 1 ? "" : "s")"
    }
}

/// The detail behind one detected series: the summary and every charge in it.
struct RecurringDetailView: View {
    @Query(sort: [SortDescriptor(\LedgerTransaction.postedDate, order: .reverse)])
    private var allTransactions: [LedgerTransaction]

    let series: RecurringSeries

    private var charges: [LedgerTransaction] {
        let ids = Set(series.transactionIDs)
        return allTransactions.filter { ids.contains($0.recurringIdentifier) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                header
                summary
                if !charges.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(title: "Charges", trailing: "\(charges.count)")
                        TransactionDayList(transactions: charges)
                    }
                }
            }
            .cairnScreen()
        }
        .cairnCanvas()
        .navigationTitle(series.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var header: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    CategoryBadge(
                        symbolName: series.categorySymbolName ?? "repeat",
                        hex: series.categoryColorHex,
                        size: 52
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(series.displayName)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text(series.cadence.displayName)
                            if series.isVariableAmount {
                                StatusPill(text: "Varies", tint: .secondary)
                            }
                            if let label = series.confidenceLabel {
                                StatusPill(text: label, tint: .secondary)
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }

                AmountText(
                    money: Money(minorUnits: abs(series.averageAmountMinorUnits), currency: series.currency),
                    showSign: series.direction == .incoming,
                    font: .cairnDisplay,
                    colorOverride: series.direction == .incoming ? CairnTheme.positive : nil
                )
                .contentTransition(.numericText())

                Text("\(series.cadence.displayName) · about "
                    + "\(Money(minorUnits: series.monthlyEquivalentMinorUnits, currency: series.currency).formatted())/mo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("Details")
                detailRow("Direction", series.direction == .outgoing ? "Money out" : "Money in")
                detailRow("Charges seen", "\(series.occurrences)")
                detailRow("Every", series.cadence.displayName)
                detailRow("First seen", series.firstDate.formatted(date: .abbreviated, time: .omitted))
                detailRow("Most recent", series.lastDate.formatted(date: .abbreviated, time: .omitted))
                detailRow(
                    series.isOverdue() ? "Was due" : "Next expected",
                    series.nextExpectedDate.formatted(date: .abbreviated, time: .omitted)
                )
                detailRow("Accounts", series.accountNames.joined(separator: ", "))
                if let categoryName = series.categoryName {
                    detailRow("Category", categoryName)
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
