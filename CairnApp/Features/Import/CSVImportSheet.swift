import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CairnCore

/// Imports a CSV export into an account, without needing a bank connection.
/// When no account exists yet it first guides the person to create a manual
/// one, so CSV remains a real path from an empty app.
struct CSVImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\Account.displayOrder)]) private var accounts: [Account]

    var onFinished: (() -> Void)?

    @State private var selectedAccount: Account?
    @State private var showingImporter = false
    @State private var showingManual = false
    @State private var payload: ImportPayload?

    private struct ImportPayload: Identifiable {
        let id = UUID()
        let account: Account
        let text: String
    }

    var body: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty {
                    ScrollView {
                        EmptyStateView(
                            systemImage: "square.and.arrow.down",
                            title: "Add an account first",
                            message: "CSV rows import into an account. Create a manual account, then choose the file.",
                            actionTitle: "Add a Manual Account"
                        ) {
                            showingManual = true
                        }
                        .cairnScreen()
                    }
                    .cairnCanvas()
                } else {
                    Form {
                        Section {
                            Picker("Account", selection: $selectedAccount) {
                                Text("Choose an account").tag(Account?.none)
                                ForEach(accounts) { account in
                                    Text(account.displayName).tag(Account?.some(account))
                                }
                            }
                        } footer: {
                            Text("Transactions are added to the account you pick. Duplicates already there are skipped.")
                        }

                        Section {
                            Button {
                                showingImporter = true
                            } label: {
                                IconRow(
                                    "Choose CSV File",
                                    subtitle: "Apple Card, Apple Savings, or a generic export",
                                    systemImage: "doc.text",
                                    tint: CairnTheme.accent
                                )
                            }
                            .disabled(selectedAccount == nil)
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            .navigationTitle("Import CSV")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImportSelection(result)
        }
        .sheet(item: $payload) { item in
            ImportTransactionsSheet(account: item.account, text: item.text) {
                onFinished?()
                dismiss()
            }
            .cairnLockCover()
        }
        .sheet(isPresented: $showingManual) {
            ManualAccountSheet { account in
                selectedAccount = account
            }
            .cairnLockCover()
        }
    }

    private func handleImportSelection(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let account = selectedAccount, let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                    model.banner = "Couldn’t read that file as text."
                    return
                }
                payload = ImportPayload(account: account, text: text)
            } catch {
                model.banner = "Couldn’t open the file: \(error.localizedDescription)"
            }
        case let .failure(error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            model.banner = "Import cancelled: \(error.localizedDescription)"
        }
    }
}
