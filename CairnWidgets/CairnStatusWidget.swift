import CairnCore
import SwiftUI
import WidgetKit

struct CairnStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: SystemSurfaceSnapshot
}

struct CairnStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> CairnStatusEntry {
        CairnStatusEntry(date: .now, snapshot: SystemSurfaceSnapshot(status: .onTrack, asOf: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (CairnStatusEntry) -> Void) {
        completion(CairnStatusEntry(date: .now, snapshot: load(at: .now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CairnStatusEntry>) -> Void) {
        let now = Date.now
        let entry = CairnStatusEntry(date: now, snapshot: load(at: now))
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(60 * 60))))
    }

    private func load(at now: Date) -> SystemSurfaceSnapshot {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "CairnAppGroupIdentifier") as? String,
              let defaults = UserDefaults(suiteName: identifier),
              let data = defaults.data(forKey: "cairn.system-surface.snapshot"),
              let snapshot = try? JSONDecoder().decode(SystemSurfaceSnapshot.self, from: data),
              snapshot.isFresh(at: now)
        else {
            return SystemSurfaceSnapshot(status: .unavailable, generatedAt: now)
        }
        return snapshot
    }
}

struct CairnStatusWidget: Widget {
    let kind = "CairnStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CairnStatusProvider()) { entry in
            VStack(alignment: .leading, spacing: 8) {
                Label("Safe to spend", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption.weight(.semibold))
                Text(entry.snapshot.statusLabel)
                    .font(.headline)
                if let asOf = entry.snapshot.asOf {
                    Text("As of \(asOf, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("As of: unavailable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Aggregate status · no merchant detail")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Cairn forecast status")
            .accessibilityValue(entry.snapshot.statusLabel)
            .widgetURL(URL(string: "cairn://insights"))
        }
        .configurationDisplayName("Cairn status")
        .description("A private, aggregate view of forecast status and data freshness.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct CairnWidgets: WidgetBundle {
    var body: some Widget { CairnStatusWidget() }
}
