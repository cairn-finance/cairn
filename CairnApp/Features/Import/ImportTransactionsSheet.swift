import SwiftUI
import CairnCore

/// Previews and imports a CSV export (Apple Card, Apple Savings, or generic)
/// into a manual account.
struct ImportTransactionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let account: Account

    @State private var document: CSVParser.Document
    @State private var preset: CSVImportPreset
    @State private var flipsSign = false
    @State private var isImporting = false

    init(account: Account, text: String) {
        self.account = account
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
                Section("File") {
                    LabeledContent("Columns", value: "\(document.headers.count)")
                    Picker("Format", selection: $preset) {
                        ForEach(CSVImportPreset.allCases, id: \.self) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    Toggle("Expenses are positive numbers", isOn: $flipsSign)
                    Text(preset.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if mapping == nil {
                    Section {
                        Label("Couldn’t find date and amount columns in this file.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(CairnTheme.negative)
                            .font(.callout)
                    }
                } else {
                    Section("Preview") {
                        if previewRows.isEmpty {
                            Text("No transactions could be read.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(previewRows.enumerated()), id: \.offset) { _, row in
                                HStack {
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
                                        font: .callout.weight(.medium)
                                    )
                                }
                            }
                        }
                    }

                    Section {
                        LabeledContent("Transactions", value: "\(parsed?.transactions.count ?? 0)")
                        if let skipped = parsed?.skippedRows, skipped > 0 {
                            LabeledContent("Skipped rows", value: "\(skipped)")
                        }
                    }
                }
            }
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
                        if isImporting { ProgressView() } else { Text("Import") }
                    }
                    .disabled(isImporting || (parsed?.transactions.isEmpty ?? true))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }

    private func performImport() {
        guard let parsed, !parsed.transactions.isEmpty else { return }
        isImporting = true
        Task {
            let outcome = await model.importTransactions(parsed.transactions, into: account)
            isImporting = false
            if let outcome {
                let skipped = outcome.duplicatesSkipped
                model.banner = "Imported \(outcome.inserted) transaction\(outcome.inserted == 1 ? "" : "s")"
                    + (skipped > 0 ? ", skipped \(skipped) duplicate\(skipped == 1 ? "" : "s")." : ".")
                dismiss()
            }
        }
    }
}
