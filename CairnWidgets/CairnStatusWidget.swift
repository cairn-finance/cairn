import CairnCore
import SwiftUI
import WidgetKit

struct CairnStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: SystemSurfaceSnapshot

    static var preview: Self {
        Self(date: .now, snapshot: SystemSurfaceSnapshot(
            status: .onTrack, asOf: .now.addingTimeInterval(-900),
            nextCommitmentDate: .now.addingTimeInterval(3 * 86_400)
        ))
    }
}

struct CairnStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> CairnStatusEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (CairnStatusEntry) -> Void) {
        completion(context.isPreview ? .preview : CairnStatusEntry(date: .now, snapshot: load(at: .now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CairnStatusEntry>) -> Void) {
        let now = Date.now
        let snapshot = load(at: now)
        let entry = CairnStatusEntry(date: now, snapshot: snapshot)
        let expiration = snapshot.generatedAt.addingTimeInterval(26 * 60 * 60 + 1)
        var entries = [entry]
        if snapshot.status != .unavailable, expiration > now {
            // Expire on time even if the system delays the next provider reload.
            entries.append(CairnStatusEntry(
                date: expiration, snapshot: SystemSurfaceSnapshot(status: .unavailable, generatedAt: expiration)
            ))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(60 * 60))))
    }

    private func load(at now: Date) -> SystemSurfaceSnapshot {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "CairnAppGroupIdentifier") as? String,
              let defaults = UserDefaults(suiteName: identifier),
              let data = defaults.data(forKey: "cairn.system-surface.snapshot"),
              let snapshot = try? JSONDecoder().decode(SystemSurfaceSnapshot.self, from: data),
              snapshot.isFresh(at: now)
        else { return SystemSurfaceSnapshot(status: .unavailable, generatedAt: now) }
        return snapshot
    }
}

struct CairnStatusWidgetView: View {
    let entry: CairnStatusEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var symbol: String {
        switch entry.snapshot.status {
        case .onTrack: "checkmark.circle.fill"
        case .review: "questionmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .unavailable: "arrow.clockwise.circle"
        }
    }

    private var tint: Color {
        guard renderingMode == .fullColor else { return .primary }
        switch entry.snapshot.status {
        case .onTrack: return Color(red: 0.1, green: 0.48, blue: 0.44)
        case .review: return .orange
        case .needsAttention: return .red
        case .unavailable: return .secondary
        }
    }

    private var explanation: LocalizedStringKey {
        switch entry.snapshot.status {
        case .onTrack: "Based on saved balances"
        case .review: "Check data and plans"
        case .needsAttention: "A shortfall is forecast"
        case .unavailable: "Open Cairn to refresh"
        }
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: symbol).font(.title2)
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 3) {
                    Label("Cairn forecast", systemImage: symbol).font(.caption.weight(.semibold))
                    Text(entry.snapshot.statusLabel).font(.headline)
                    Text(explanation).font(.caption)
                }
            case .systemSmall:
                compactContent
            default:
                homeScreenContent
            }
        }
        .containerBackground(for: .widget) {
            Color(uiColor: .systemBackground)
                .overlay(alignment: .topTrailing) {
                    LinearGradient(colors: [tint.opacity(0.12), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cairn cash-flow forecast")
        .accessibilityValue(entry.snapshot.statusLabel)
        .accessibilityHint("Opens the forecast and confirmed plans in Cairn")
        .widgetURL(SystemSurfaceDestination.forecast.url)
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .widgetAccentable()
                Text("Forecast")
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            Text(entry.snapshot.statusLabel)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(entry.snapshot.status == .onTrack ? "30-day outlook" : explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            compactFreshness
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var homeScreenContent: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cairn forecast")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .widgetAccentable()
                Text(entry.snapshot.statusLabel)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            if family == .systemMedium {
                VStack(alignment: .leading, spacing: 10) {
                    if let dueDate = entry.snapshot.nextCommitmentDate {
                        Label("Next plan", systemImage: "calendar")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(dueDate, format: .dateTime.month(.abbreviated).day())
                            .font(.title3.weight(.medium))
                    } else {
                        Label("30-day outlook", systemImage: "chart.xyaxis.line")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    freshness.font(.caption)
                    Label("Open forecast", systemImage: "arrow.up.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var freshness: some View {
        if entry.snapshot.status != .unavailable {
            if let asOf = entry.snapshot.asOf {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Last sync").foregroundStyle(.secondary)
                    Text(asOf, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("From saved data").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var compactFreshness: some View {
        if entry.snapshot.status != .unavailable {
            if let asOf = entry.snapshot.asOf {
                if Calendar.current.isDate(asOf, inSameDayAs: entry.date) {
                    Text("Synced \(asOf.formatted(.dateTime.hour().minute()))")
                } else {
                    Text("Synced \(asOf.formatted(.dateTime.month(.abbreviated).day()))")
                }
            } else {
                Text("From saved data")
            }
        }
    }
}

struct CairnStatusWidget: Widget {
    let kind = "CairnStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CairnStatusProvider()) { entry in
            CairnStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Cash-flow outlook")
        .description("Your forecast status and next plan, with amounts and merchant names kept private.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

@main
struct CairnWidgets: WidgetBundle {
    var body: some Widget { CairnStatusWidget() }
}

#Preview(as: .systemSmall) { CairnStatusWidget() } timeline: { CairnStatusEntry.preview }
#Preview(as: .systemMedium) { CairnStatusWidget() } timeline: { CairnStatusEntry.preview }
#Preview(as: .accessoryRectangular) { CairnStatusWidget() } timeline: { CairnStatusEntry.preview }
