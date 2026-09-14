import SwiftUI
import CairnCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Shows the in-memory sync log so a person can copy it and share it when
/// asking for help. The log never contains credentials, balances, amounts, or
/// transaction descriptions.
struct SyncDiagnosticsView: View {
    @State private var entries: [DiagnosticsLog.Entry] = []
    @State private var copied = false

    var body: some View {
        List {
            if entries.isEmpty {
                Section {
                    Text("No sync activity logged yet. Run a sync, then come back to this screen.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: entry.level))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("This log stays on this device and contains no credentials, balances, or transaction details.")
                }
            }
        }
        .cairnListStyle()
        .navigationTitle("Sync Diagnostics")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    copyAll()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(entries.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    Task {
                        await DiagnosticsLog.shared.clear()
                        await refresh()
                    }
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(entries.isEmpty)
            }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        entries = await DiagnosticsLog.shared.snapshot()
    }

    private func color(for level: DiagnosticsLog.Level) -> Color {
        switch level {
        case .info: .primary
        case .warning: .orange
        case .error: CairnTheme.negative
        }
    }

    private func copyAll() {
        Task {
            let text = await DiagnosticsLog.shared.text()
            #if os(iOS)
            UIPasteboard.general.string = text
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
            copied = true
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
