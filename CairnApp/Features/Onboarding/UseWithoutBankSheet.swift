import SwiftUI
import CairnCore

/// The "use without a bank" path from onboarding. Explains that Cairn works
/// fully without SimpleFIN, then opens either a manual account or a CSV import.
/// No bank connection is required or implied.
struct UseWithoutBankSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Called once the person is ready to continue into the app.
    var onReady: () -> Void

    @State private var showingManual = false
    @State private var showingImport = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                SettingsIcon(systemImage: "square.and.pencil", tint: CairnTheme.accent)
                                Text("Use Cairn without a bank")
                                    .font(.headline)
                            }
                            Text("Cairn doesn’t need SimpleFIN to be useful. Add an account by hand and "
                                + "import a CSV export from your bank or card, or just look around and add "
                                + "a connection later.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Button {
                        showingManual = true
                    } label: {
                        Label("Add a Manual Account", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.cairnProminent)

                    Button {
                        showingImport = true
                    } label: {
                        Label("Import a CSV", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.cairnSecondary)
                }
                .cairnScreen()
            }
            .cairnCanvas()
            .navigationTitle("Use without a bank")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { finish() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 460)
        #endif
        .sheet(isPresented: $showingManual) {
            ManualAccountSheet(onCreated: { _ in finish() })
                .cairnLockCover()
        }
        .sheet(isPresented: $showingImport) {
            CSVImportSheet(onFinished: finish)
                .cairnLockCover()
        }
    }

    /// Closes this sheet before telling the caller the person is ready, rather
    /// than relying on the root view swapping onboarding out from under it.
    private func finish() {
        dismiss()
        onReady()
    }
}
