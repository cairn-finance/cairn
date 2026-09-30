import CairnCore
import SwiftUI
import WidgetKit

struct CairnFinancialEntry: TimelineEntry {
    let date: Date
    let snapshot: FinancialWidgetSnapshot?
    let isMonthCurrent: Bool

    static var preview: Self {
        let now = Date.now
        let monthStart = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        return Self(
            date: now,
            snapshot: FinancialWidgetSnapshot(
                generatedAt: now,
                primaryCurrency: .usd,
                netWorth: [FinancialWidgetAmount(currency: .usd, amountMinorUnits: 12_485_000)],
                monthToDateSpend: [FinancialWidgetAmount(currency: .usd, amountMinorUnits: 184_250)],
                monthStart: monthStart
            ),
            isMonthCurrent: true
        )
    }
}

struct CairnFinancialProvider: TimelineProvider {
    func placeholder(in context: Context) -> CairnFinancialEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (CairnFinancialEntry) -> Void) {
        let now = Date.now
        completion(context.isPreview ? .preview : entry(at: now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CairnFinancialEntry>) -> Void) {
        let now = Date.now
        var entries = [entry(at: now)]
        if let snapshot = entries[0].snapshot,
           let nextMonth = Calendar.current.dateInterval(of: .month, for: now)?.end,
           nextMonth > now {
            entries.append(CairnFinancialEntry(
                date: nextMonth,
                snapshot: snapshot.isFresh(at: nextMonth) ? snapshot : nil,
                isMonthCurrent: false
            ))
        }
        if let snapshot = entries[0].snapshot {
            let expiration = snapshot.generatedAt.addingTimeInterval(26 * 60 * 60)
            if expiration > now {
                entries.append(CairnFinancialEntry(date: expiration, snapshot: nil, isMonthCurrent: false))
            }
        }
        entries.sort { $0.date < $1.date }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(12 * 60 * 60))))
    }

    private func entry(at date: Date) -> CairnFinancialEntry {
        let snapshot = load(at: date)
        return CairnFinancialEntry(
            date: date,
            snapshot: snapshot,
            isMonthCurrent: snapshot?.includesCurrentMonth(at: date) ?? false
        )
    }

    private func load(at now: Date) -> FinancialWidgetSnapshot? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "CairnAppGroupIdentifier") as? String,
              let defaults = UserDefaults(suiteName: identifier),
              let data = defaults.data(forKey: FinancialWidgetSnapshot.sharedDefaultsKey),
              let snapshot = try? JSONDecoder().decode(FinancialWidgetSnapshot.self, from: data),
              snapshot.isFresh(at: now)
        else { return nil }
        return snapshot
    }
}

private enum CairnFinancialMetric {
    case netWorth
    case monthToDateSpend

    var title: LocalizedStringKey {
        switch self {
        case .netWorth: "Net worth"
        case .monthToDateSpend: "Month to date"
        }
    }

    var symbol: String {
        switch self {
        case .netWorth: "chart.pie.fill"
        case .monthToDateSpend: "arrow.up.right"
        }
    }

    var destination: SystemSurfaceDestination {
        switch self {
        case .netWorth: .netWorth
        case .monthToDateSpend: .activity
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .netWorth: String(localized: "Net worth")
        case .monthToDateSpend: String(localized: "Month-to-date spending")
        }
    }
}

private struct CairnFinancialWidgetView: View {
    let entry: CairnFinancialEntry
    let metric: CairnFinancialMetric

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var amount: FinancialWidgetAmount? {
        guard let snapshot = entry.snapshot else { return nil }
        switch metric {
        case .netWorth:
            return snapshot.netWorth.first { $0.currency == snapshot.primaryCurrency }
        case .monthToDateSpend:
            return snapshot.monthToDateSpend.first { $0.currency == snapshot.primaryCurrency }
                ?? FinancialWidgetAmount(currency: snapshot.primaryCurrency, amountMinorUnits: 0)
        }
    }

    private var unavailableMessage: String? {
        guard let snapshot = entry.snapshot else { return String(localized: "Open Cairn to refresh") }
        switch metric {
        case .netWorth:
            return snapshot.netWorth.isEmpty ? String(localized: "Add an account in Cairn") : nil
        case .monthToDateSpend:
            return entry.isMonthCurrent ? nil : String(localized: "Open Cairn to refresh this month")
        }
    }

    private var otherCurrencyCount: Int {
        guard let snapshot = entry.snapshot else { return 0 }
        let amounts: [FinancialWidgetAmount]
        switch metric {
        case .netWorth: amounts = snapshot.netWorth
        case .monthToDateSpend: amounts = snapshot.monthToDateSpend
        }
        return amounts.filter { $0.currency != snapshot.primaryCurrency }.count
    }

    private var tint: Color {
        renderingMode == .fullColor ? Color(red: 0.12, green: 0.48, blue: 0.44) : .primary
    }

    var body: some View {
        Group {
            if family == .systemMedium {
                mediumContent
            } else {
                compactContent
            }
        }
        .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(metric.accessibilityTitle)
        .accessibilityValue(accessibilityAmount)
        .accessibilityHint(accessibilityHint)
        .widgetURL(metric.destination.url)
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            heading
            Spacer(minLength: 0)
            value(fontSize: 29)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumContent: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                heading
                Spacer(minLength: 0)
                value(fontSize: 34)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Label("Cairn", systemImage: "mountain.2.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                if otherCurrencyCount > 0 {
                    Text("Plus \(otherCurrencyCount) other currencies")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                freshness
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var heading: some View {
        Label(metric.title, systemImage: metric.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private func value(fontSize: CGFloat) -> some View {
        if let unavailableMessage {
            Text(verbatim: unavailableMessage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)
        } else if let amount {
            Text(verbatim: Money(minorUnits: amount.amountMinorUnits, currency: amount.currency).formatted())
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .widgetAccentable()
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
    }

    private var footer: some View {
        Group {
            if let snapshot = entry.snapshot, unavailableMessage == nil {
                HStack(spacing: 4) {
                    Text("Updated")
                    Text(snapshot.generatedAt, format: .dateTime.month(.abbreviated).day())
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else if let unavailableMessage {
                Text(verbatim: unavailableMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var freshness: some View {
        if let snapshot = entry.snapshot, unavailableMessage == nil {
            VStack(alignment: .leading, spacing: 3) {
                Text("Updated")
                    .foregroundStyle(.secondary)
                Text(snapshot.generatedAt, format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        } else if let unavailableMessage {
            Text(verbatim: unavailableMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilityAmount: String {
        guard let amount, unavailableMessage == nil else {
            return unavailableMessage ?? String(localized: "Not available")
        }
        return Money(minorUnits: amount.amountMinorUnits, currency: amount.currency).formatted()
    }

    private var accessibilityHint: String {
        switch metric {
        case .netWorth: String(localized: "Opens net worth in Cairn")
        case .monthToDateSpend: String(localized: "Opens activity in Cairn")
        }
    }
}

struct CairnNetWorthWidget: Widget {
    let kind = "CairnNetWorthWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CairnFinancialProvider()) { entry in
            CairnFinancialWidgetView(entry: entry, metric: .netWorth)
        }
        .configurationDisplayName("Net worth")
        .description("See net worth in your primary currency.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct CairnMonthToDateSpendWidget: Widget {
    let kind = "CairnMonthToDateSpendWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CairnFinancialProvider()) { entry in
            CairnFinancialWidgetView(entry: entry, metric: .monthToDateSpend)
        }
        .configurationDisplayName("Month-to-date spend")
        .description("See posted spending so far this month in your primary currency.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) { CairnNetWorthWidget() } timeline: { CairnFinancialEntry.preview }
#Preview(as: .systemMedium) { CairnNetWorthWidget() } timeline: { CairnFinancialEntry.preview }
#Preview(as: .systemSmall) { CairnMonthToDateSpendWidget() } timeline: { CairnFinancialEntry.preview }
#Preview(as: .systemMedium) { CairnMonthToDateSpendWidget() } timeline: { CairnFinancialEntry.preview }
