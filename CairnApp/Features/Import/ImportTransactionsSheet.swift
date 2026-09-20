import SwiftUI
import CairnCore

/// Previews and imports a CSV export (Apple Card, Apple Savings, or generic)
/// into a manual account.
struct ImportTransactionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let account: Account
    /// Called after a successful import, so a caller can continue or close.
    var onImported: (() -> Void)?

    @State private var document: CSVParser.Document
    @State private var preset: CSVImportPreset
    @State private var flipsSign = false
    @State private var isImporting = false

    init(account: Account, text: String, onImported: (() -> Void)? = nil) {
        self.account = account
        self.onImported = onImported
        let parsedDocument = CSVParser.parse(text)
        _document = State(initialValue: parsedDocument)
        // Pick the Apple Card preset automatically when its headers are present.
        let looksLikeAppleCard = parsedDocument.headers.contains { $0.caseInsensitiveCompare("Merchant") == .orderedSame }
            && parsedDocument.headers.contains { $0.localizedCaseInsensitiveContains("Transaction Date") }
        _preset = State(initialValue: looksLikeAppleCard ? .appleCard : .generic)
    }

    private var mapping: CSVImportMapping? {
        guard var resolved = CSVColumnResolver.resolve(headers: document.headers, preset: preset) else { return nil }
        resolved.flipsSign = flipsSign
        return resolved
    }

    private var parsed: CSVImportResult? {
        guard let mapping else { return nil }
        return CSVImportParser.parse(document, mapping: mapping, currency: account.currency)
    }

    private var previewRows: [ImportedTransaction] {
        Array((parsed?.transactions ?? []).prefix(6))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    IconRow("Format", systemImage: "doc.text", tint: CairnTheme.accent) {
                        Picker("Format", selection: $preset) {
                            ForEach(CSVImportPreset.allCases, id: \.self) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .labelsHidden()
                    }
                    Toggle(isOn: $flipsSign) {
                        IconRow("Expenses are positive numbers", systemImage: "plusminus", tint: .orange)
                    }
                } header: {
                    Text("File")
                } footer: {
                    Text("\(document.headers.count) columns detected. \(preset.summary)")
                }

                if mapping == nil {
                    Section {
                        Label("Couldn’t find date and amount columns in this file.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(CairnTheme.negative)
                            .font(.callout)
                    }
                } else {
                    Section {
                        if previewRows.isEmpty {
                            Text("No transactions could be read.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(previewRows.enumerated()), id: \.offset) { _, row in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.description.isEmpty ? row.merchant : row.description)
                                            .lineLimit(1)
                                        Text(row.date, format: .dateTime.year().month().day())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    AmountText(
                                        money: Money(minorUnits: row.amountMinorUnits, currency: account.currency),
                                        showSign: true,
                                        font: .callout.weight(.semibold),
                                        colorOverride: row.amountMinorUnits > 0 ? CairnTheme.positive : nil
                                    )
                                }
                            }
                        }
                    } header: {
                        Text("Preview")
                    } footer: {
                        summaryFooter
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import to \(account.displayName)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        performImport()
                    } label: {
                        if isImporting {
                            ProgressView()
                        } else {
                            Text("Import \(parsed?.transactions.count ?? 0)")
                        }
                    }
                    .disabled(isImporting || (parsed?.transactions.isEmpty ?? true))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 540)
        #endif
    }

    @ViewBuilder
    private var summaryFooter: some View {
        let count = parsed?.transactions.count ?? 0
        let skipped = parsed?.skippedRows ?? 0
        if skipped > 0 {
            Text("^[\(count) transaction](inflect: true) ready to import, ^[\(skipped) row](inflect: true) skipped.")
        } else {
            Text("^[\(count) transaction](inflect: true) ready to import. Duplicates are skipped automatically.")
        }
    }

    private func performImport() {
        guard let parsed, !parsed.transactions.isEmpty else { return }
        isImporting = true
        Task {
            let outcome = await model.importTransactions(parsed.transactions, into: account)
            isImporting = false
            if let outcome {
                let skipped = outcome.duplicatesSkipped
                if skipped > 0 {
                    model.banner = String(
                        localized: "Imported ^[\(outcome.inserted) transaction](inflect: true), skipped \(skipped)."
                    )
                } else {
                    model.banner = String(localized: "Imported ^[\(outcome.inserted) transaction](inflect: true).")
                }
                // A caller that supplies a callback owns dismissal, so the
                // sheet is not told to close twice.
                if let onImported {
                    onImported()
                } else {
                    dismiss()
                }
            }
        }
    }
}
