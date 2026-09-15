import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CairnCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Institution.name) private var institutions: [Institution]
    @Query(filter: #Predicate<Account> { $0.sourceRaw == "financekit" })
    private var walletAccounts: [Account]

    @State private var storageMode: StoreMode = .local
    @State private var exportDocument: ExportFile?
    @State private var exportType: UTType = .commaSeparatedText
    @State private var showingExporter = false
    @State private var showingDeleteConfirm = false
    @State private var showingConnect = false
    @State private var showingWalletDisconnect = false
    @State private var institutionToDisconnect: Institution?

    /// The most recent successful fetch across all banks.
    private var lastSuccessfulSync: Date? {
        institutions.compactMap(\.lastSuccessfulFetch).max()
    }

    /// Hides the connection-less credential holder once its connections have
    /// been split out, but keeps it visible when it is the only record (for
    /// example a first connect that never succeeded) so it can be disconnected.
    private var visibleInstitutions: [Institution] {
        institutions.filter { institution in
            if !institution.bankConnectionID.isEmpty || institution.lastSyncError != nil {
                return true
            }
            let hasChildren = institutions.contains {
                $0.credentialID == institution.credentialID
                    && $0.persistentModelID != institution.persistentModelID
            }
            return !hasChildren
        }
    }

    var body: some View {
        Form {
            syncSection
            institutionsSection
            categorizationSection
            storageSection
            privacySection
            dataSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { storageMode = model.storeMode }
        .sheet(isPresented: $showingConnect) {
            AddConnectionSheet { showingConnect = false }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: "cairn-transactions"
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
            Text("The stored credential is removed from the Keychain and local data is deleted. "
                + "Banks that share this SimpleFIN connection are disconnected too. "
                + "Revoke access at SimpleFIN as well if you want to be certain.")
        }
        .confirmationDialog(
            "Remove Apple Wallet data?",
            isPresented: $showingWalletDisconnect,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task { await model.disconnectWallet() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the Wallet accounts and transactions Cairn imported. "
                + "It can’t revoke access; change that in Settings › Privacy & Security › Financial Data.")
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            IconRow("Last successful sync", systemImage: "arrow.triangle.2.circlepath", tint: CairnTheme.accent) {
                if let date = lastSuccessfulSync {
                    Text(date, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never").foregroundStyle(.secondary)
                }
            }
            IconRow("Requests left today", systemImage: "gauge.with.dots.needle.33percent", tint: .orange) {
                Text("\(model.remainingBudget) of \(SyncEngine.dailyRequestLimit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await model.syncAll(force: true) }
            } label: {
                IconRow(model.syncState == .syncing ? "Syncing…" : "Sync Now", systemImage: "arrow.clockwise", tint: CairnTheme.accent) {
                    if model.syncState == .syncing {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(model.syncState == .syncing || institutions.isEmpty)
            NavigationLink {
                SyncDiagnosticsView()
            } label: {
                IconRow("Sync Diagnostics", systemImage: "doc.text.magnifyingglass", tint: .gray)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Each bank has its own SimpleFIN daily budget, shared across your devices. Cairn shows the smallest and refreshes conservatively.")
        }
    }

    // MARK: - Institutions

    private var institutionsSection: some View {
        Section {
            ForEach(visibleInstitutions) { institution in
                HStack(spacing: 12) {
                    SettingsIcon(systemImage: "building.columns.fill", tint: institution.lastSyncError == nil ? CairnTheme.accent : CairnTheme.negative)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(institution.name.isEmpty ? "Institution" : institution.name)
                        if let error = institution.lastSyncError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(CairnTheme.negative)
                                .lineLimit(2)
                        } else if let date = institution.lastSyncDate {
                            Text("Synced \(date.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not synced yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(institution.accounts?.count ?? 0)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .swipeActions {
                    Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                        institutionToDisconnect = institution
                    }
                }
                .contextMenu {
                    Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                        institutionToDisconnect = institution
                    }
                }
            }
            if !walletAccounts.isEmpty {
                HStack(spacing: 12) {
                    SettingsIcon(systemImage: "wallet.pass.fill", tint: CairnTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Apple Wallet")
                        Text("\(walletAccounts.count) \(walletAccounts.count == 1 ? "account" : "accounts")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .swipeActions {
                    Button("Remove", systemImage: "xmark.circle", role: .destructive) {
                        showingWalletDisconnect = true
                    }
                }
                .contextMenu {
                    Button("Remove", systemImage: "xmark.circle", role: .destructive) {
                        showingWalletDisconnect = true
                    }
                }
            }
            Button {
                showingConnect = true
            } label: {
                IconRow("Add a Connection", systemImage: "plus", tint: CairnTheme.positive)
            }
        } header: {
            Text("Institutions")
        } footer: {
            if !institutions.isEmpty {
                Text("Swipe an institution to disconnect it.")
            }
        }
    }

    // MARK: - Categorization

    private var categorizationSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.useAppleIntelligence },
                set: { model.useAppleIntelligence = $0 }
            )) {
                IconRow("Use Apple Intelligence", subtitle: AppleIntelligenceCategorizer.statusDescription, systemImage: "sparkles", tint: Color(red: 0.62, green: 0.36, blue: 0.87))
            }
            .disabled(!AppleIntelligenceCategorizer.isAvailable)
        } header: {
            Text("Categorization")
        } footer: {
            Text("Rules and your past corrections always run on-device, automatically after every sync and import. "
                + "Apple Intelligence is used only for what they can’t place, and only its on-device model — never the cloud.")
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            Picker(selection: $storageMode) {
                Text(StoreMode.cloud.displayName).tag(StoreMode.cloud)
                Text(StoreMode.local.displayName).tag(StoreMode.local)
            } label: {
                IconRow("Where data lives", systemImage: storageMode == .cloud ? "icloud.fill" : "internaldrive.fill", tint: storageMode == .cloud ? .blue : .gray)
            }
            .onChange(of: storageMode) { _, newValue in
                guard newValue != model.storeMode else { return }
                model.requestStoreModeChange(to: newValue)
            }
            if let reason = model.cloudFallbackReason {
                Label("iCloud isn’t available right now, so Cairn is using local storage. \(reason)", systemImage: "icloud.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("\(storageMode.summary) Changing this takes effect after you quit and reopen Cairn. "
                + "Turning sync off only stops future uploads; to remove data already in iCloud, use Delete All Data.")
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.appLockEnabled },
                set: { model.setAppLock(enabled: $0) }
            )) {
                IconRow("Require unlock to open", systemImage: "faceid", tint: CairnTheme.positive)
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("The app lock guards the interface. The SimpleFIN credential stays in the Keychain so background sync can work, and can be revoked at any time from your SimpleFIN Bridge.")
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            Button { export(json: false) } label: {
                IconRow("Export as CSV", systemImage: "tablecells", tint: .blue)
            }
            Button { export(json: true) } label: {
                IconRow("Export as JSON", systemImage: "curlybraces", tint: .indigo)
            }
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                IconRow("Delete All Data", systemImage: "trash.fill", tint: CairnTheme.negative)
                    .foregroundStyle(CairnTheme.negative)
            }
        } header: {
            Text("Your data")
        } footer: {
            Text("Exports include every transaction and your categories and notes. Nothing is uploaded; the file is shared through the system share sheet.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            IconRow("Version", systemImage: "mountain.2.fill", tint: CairnTheme.ink) {
                Text(appVersion).foregroundStyle(.secondary)
            }
            Link(destination: URL(string: "https://github.com/sehejjain/cairn")!) {
                IconRow("Source Code", systemImage: "chevron.left.forwardslash.chevron.right", tint: .gray) {
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            Link(destination: URL(string: "https://github.com/sehejjain/cairn/blob/main/docs/privacy-policy.md")!) {
                IconRow("Privacy Policy", systemImage: "hand.raised.fill", tint: .gray) {
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("About")
        } footer: {
            Text("Cairn is not affiliated with SimpleFIN or any bank. It reads data you authorize and never moves money.")
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
