import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CairnCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Institution.name) private var institutions: [Institution]

    @State private var storageMode: StoreMode = .local
    @State private var exportDocument: ExportFile?
    @State private var exportType: UTType = .commaSeparatedText
    @State private var showingExporter = false
    @State private var showingDeleteConfirm = false
    @State private var institutionToDisconnect: Institution?

    /// The most recent successful fetch across all banks.
    private var lastSuccessfulSync: Date? {
        institutions.compactMap(\.lastSuccessfulFetch).max()
    }

    var body: some View {
        Form {
            syncSection
            storageSection
            institutionsSection
            privacySection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { storageMode = model.storeMode }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: exportType == .json ? "cairn-transactions" : "cairn-transactions"
        ) { _ in }
        .confirmationDialog(
            "Delete all Cairn data?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                Task { await model.deleteAllData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes every account, transaction, category, and stored credential from this device and, "
                + "if iCloud Sync is on, from your iCloud database. This cannot be undone. "
                + "Export first if you want a copy."
            )
        }
        .confirmationDialog(
            "Disconnect \(institutionToDisconnect?.name ?? "institution")?",
            isPresented: Binding(
                get: { institutionToDisconnect != nil },
                set: { if !$0 { institutionToDisconnect = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                if let institution = institutionToDisconnect {
                    Task { await model.disconnect(institution) }
                }
                institutionToDisconnect = nil
            }
            Button("Cancel", role: .cancel) { institutionToDisconnect = nil }
        } message: {
            Text("The stored credential is removed from the Keychain and local data is deleted. Revoke access at SimpleFIN as well if you want to be certain.")
        }
    }

    private var syncSection: some View {
        Section("Sync") {
            LabeledContent("Last successful sync") {
                if let date = lastSuccessfulSync {
                    Text(date, format: .dateTime.month().day().hour().minute())
                } else {
                    Text("Never").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Requests left today") {
                Text("\(model.remainingBudget) of \(SyncEngine.dailyRequestLimit)")
                    .monospacedDigit()
            }
            Text("Each bank has its own SimpleFIN daily budget, shared across your devices. Cairn shows the smallest and refreshes conservatively.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await model.syncAll(force: true) }
            } label: {
                if model.syncState == .syncing {
                    Text("Syncing…")
                } else {
                    Text("Sync Now")
                }
            }
            .disabled(model.syncState == .syncing)
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            Picker("Where data lives", selection: $storageMode) {
                Text(StoreMode.cloud.displayName).tag(StoreMode.cloud)
                Text(StoreMode.local.displayName).tag(StoreMode.local)
            }
            .onChange(of: storageMode) { _, newValue in
                guard newValue != model.storeMode else { return }
                model.requestStoreModeChange(to: newValue)
            }
            Text(storageMode.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Changing this takes effect after you quit and reopen Cairn. Turning sync off only stops future uploads; to remove data already in iCloud, use Delete All Data.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let reason = model.cloudFallbackReason {
                Label("iCloud isn’t available right now, so Cairn is using local storage. \(reason)", systemImage: "icloud.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var institutionsSection: some View {
        Section("Institutions") {
            if institutions.isEmpty {
                Text("No institutions connected.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(institutions) { institution in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(institution.name.isEmpty ? "Institution" : institution.name)
                        if let error = institution.lastSyncError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(CairnTheme.negative)
                                .lineLimit(2)
                        } else if let date = institution.lastSyncDate {
                            Text("Synced \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Disconnect", role: .destructive) {
                            institutionToDisconnect = institution
                        }
                    }
                }
            }
        }
    }

    private var privacySection: some View {
        Section("Privacy & Data") {
            Toggle("Require unlock to open Cairn", isOn: Binding(
                get: { model.appLockEnabled },
                set: { model.setAppLock(enabled: $0) }
            ))
            Text("The app lock guards the interface. The SimpleFIN credential stays in the Keychain so background sync can work, and can be revoked at any time from your SimpleFIN Bridge.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Export as CSV") { export(json: false) }
            Button("Export as JSON") { export(json: true) }
            Text("Exports include every transaction and your categories and notes. Nothing is uploaded; the file is shared through the system share sheet.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Delete All Data", role: .destructive) {
                showingDeleteConfirm = true
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: appVersion)
            Link("Source Code", destination: URL(string: "https://github.com/sehejjain/cairn")!)
            Link("Privacy Policy", destination: URL(string: "https://github.com/sehejjain/cairn/blob/main/docs/privacy-policy.md")!)
            Text("Cairn is not affiliated with SimpleFIN or any bank. It reads data you authorize and never moves money.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func export(json: Bool) {
        Task {
            guard let data = await model.exportData(json: json) else { return }
            exportDocument = ExportFile(data: data)
            exportType = json ? .json : .commaSeparatedText
            showingExporter = true
        }
    }
}

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
