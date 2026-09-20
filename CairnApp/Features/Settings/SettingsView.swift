import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CairnCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Institution.name) private var institutions: [Institution]
    @Query(filter: #Predicate<Account> { $0.sourceRaw == "financekit" })
    private var walletAccounts: [Account]
    @Query(sort: \CategorizationRule.createdAt) private var rules: [CategorizationRule]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: [SortDescriptor(\CairnSchemaV1.Category.sortOrder)])
    private var categories: [CairnSchemaV1.Category]

    @State private var storageMode: StoreMode = .local
    @State private var exportDocument: ExportFile?
    @State private var exportType: UTType = .commaSeparatedText
    @State private var showingExporter = false
    @State private var showingDeleteConfirm = false
    @State private var showingConnect = false
    @State private var showingWalletDisconnect = false
    @State private var institutionToDisconnect: Institution?
    @State private var credentialToForget: AppModel.RecoverableCredential?

    /// The most recent successful fetch across all banks.
    private var lastSuccessfulSync: Date? {
        institutions.compactMap(\.lastSuccessfulFetch).max()
    }

    /// The banks to list. `Institution.listedAsBanks` hides the connection-less
    /// credential holder so a SimpleFIN Access URL never looks like a bank.
    private var visibleInstitutions: [Institution] {
        Institution.listedAsBanks(institutions)
    }

    /// Wallet accounts are written by FinanceKit on iPhone/iPad and reach other
    /// devices through iCloud, so the count alone understates how they update.
    private var walletSubtitle: LocalizedStringKey {
        let count = walletAccounts.count
        #if os(macOS)
        return "^[\(count) account](inflect: true) · Updates on your iPhone"
        #else
        return "^[\(count) account](inflect: true)"
        #endif
    }

    var body: some View {
        Form {
            syncSection
            institutionsSection
            categorizationSection
            organizationSection
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
                .cairnLockCover()
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: "cairn-transactions"
        ) { result in
            if case let .failure(error) = result {
                // Cancelling the save dialog is a choice, not a failure.
                guard (error as? CocoaError)?.code != .userCancelled else { return }
                model.banner = "Export failed: \(error.localizedDescription)"
            }
        }
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
            Text("This removes all your data from this device and, if iCloud Sync is on, from iCloud. It cannot be undone.")
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
            Text("The stored credential is removed from the Keychain and local data is deleted. Shared banks disconnect too.")
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
            Text("This deletes the Wallet accounts and transactions Cairn imported. To revoke access, change it in Settings.")
        }
        .confirmationDialog(
            "Forget the saved connection?",
            isPresented: Binding(
                get: { credentialToForget != nil },
                set: { if !$0 { credentialToForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget Connection", role: .destructive) {
                if let credential = credentialToForget { model.forget(credential) }
                credentialToForget = nil
            }
            Button("Cancel", role: .cancel) { credentialToForget = nil }
        } message: {
            Text("This removes the saved SimpleFIN connection from this device. Reconnecting needs a new setup token.")
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            IconRow(
                "Connection",
                systemImage: model.isOffline ? "wifi.slash" : "wifi",
                tint: model.isOffline ? CairnTheme.warning : CairnTheme.positive
            ) {
                Text(model.isOffline ? "Offline" : "Online")
                    .foregroundStyle(.secondary)
            }
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
                IconRow(
                    model.syncState == .syncing ? "Syncing…" : "Sync Now",
                    systemImage: "arrow.clockwise",
                    tint: CairnTheme.accent
                ) {
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
            Text("Each bank has its own SimpleFIN daily budget, shared across your devices. Cairn shows the smallest."
                + (model.isOffline
                    ? " You’re offline right now, so sync is paused; your saved data still works and sync resumes automatically."
                    : ""))
        }
    }

    // MARK: - Institutions

    private var institutionsSection: some View {
        Section {
            ForEach(visibleInstitutions) { institution in
                HStack(spacing: 12) {
                    SettingsIcon(
                        systemImage: "building.columns.fill",
                        tint: institution.lastSyncError == nil ? CairnTheme.accent : CairnTheme.negative
                    )
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
            ForEach(model.recoverableCredentials) { credential in
                HStack(spacing: 12) {
                    SettingsIcon(systemImage: "arrow.triangle.2.circlepath", tint: CairnTheme.positive)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Saved SimpleFIN connection")
                        Text("\(credential.host) · Reconnect without a new token")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.reconnectingCredentialIDs.contains(credential.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Reconnect") {
                            Task { await model.reconnect(credential) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .swipeActions {
                    Button("Forget", systemImage: "trash", role: .destructive) {
                        credentialToForget = credential
                    }
                }
                .contextMenu {
                    Button("Forget", systemImage: "trash", role: .destructive) {
                        credentialToForget = credential
                    }
                }
            }
            if !walletAccounts.isEmpty {
                HStack(spacing: 12) {
                    SettingsIcon(systemImage: "wallet.pass.fill", tint: CairnTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Apple Wallet")
                        Text(walletSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                // A Mac's Wallet removal cannot stick while an iPhone is
                // authorized — the iPhone re-imports the cards — so the action
                // is only offered where FinanceKit can own the data. See
                // docs/wallet-sync.md.
                #if os(iOS)
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
                #endif
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
                IconRow(
                    "Use Apple Intelligence",
                    subtitle: "\(AppleIntelligenceCategorizer.deviceProfile.summary)",
                    systemImage: "sparkles",
                    tint: Color(red: 0.62, green: 0.36, blue: 0.87)
                )
            }
            .disabled(!AppleIntelligenceCategorizer.isAvailable)

            Toggle(isOn: Binding(
                get: { model.categorizeOnlyWhileCharging },
                set: { model.categorizeOnlyWhileCharging = $0 }
            )) {
                IconRow(
                    "Only categorize while charging",
                    subtitle: "The bulk pass waits for a charger. Recent activity is still categorized right away.",
                    systemImage: "battery.100.bolt",
                    tint: CairnTheme.positive
                )
            }
            .disabled(!model.useAppleIntelligence || !AppleIntelligenceCategorizer.isAvailable)
        } header: {
            Text("Categorization")
        } footer: {
            Text("Rules and corrections run on-device after every sync. Apple Intelligence fills what they can’t.")
        }
    }

    // MARK: - Organization

    private var organizationSection: some View {
        Section {
            NavigationLink {
                RulesView()
            } label: {
                IconRow(
                    "Rules",
                    subtitle: rulesSubtitle,
                    systemImage: "slider.horizontal.3",
                    tint: Color(red: 0.62, green: 0.36, blue: 0.87)
                )
            }
            NavigationLink {
                TagsView()
            } label: {
                IconRow(
                    "Tags",
                    subtitle: tagsSubtitle,
                    systemImage: "tag.fill",
                    tint: Color(red: 0.20, green: 0.68, blue: 0.90)
                )
            }
            NavigationLink {
                CategoriesView()
            } label: {
                IconRow(
                    "Categories",
                    subtitle: categoriesSubtitle,
                    systemImage: "square.grid.2x2.fill",
                    tint: Color(red: 0.98, green: 0.58, blue: 0.20)
                )
            }
        } header: {
            Text("Organization")
        } footer: {
            Text("Rules match the bank description or amount and assign a category. Tags are free-form labels.")
        }
    }

    private var rulesSubtitle: LocalizedStringKey {
        let count = rules.count
        return count == 0 ? "None yet" : "^[\(count) rule](inflect: true)"
    }

    private var tagsSubtitle: LocalizedStringKey {
        let count = tags.count
        return count == 0 ? "None yet" : "^[\(count) tag](inflect: true)"
    }

    private var categoriesSubtitle: LocalizedStringKey {
        let count = categories.filter { !$0.isArchived }.count
        return "^[\(count) category](inflect: true)"
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            Picker(selection: $storageMode) {
                Text(StoreMode.cloud.displayName).tag(StoreMode.cloud)
                Text(StoreMode.local.displayName).tag(StoreMode.local)
            } label: {
                IconRow(
                    "Where data lives",
                    systemImage: storageMode == .cloud ? "icloud.fill" : "internaldrive.fill",
                    tint: storageMode == .cloud ? .blue : .gray
                )
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
                + deleteDataNote)
        }
    }

    /// The storage footer used to tell everyone to "use Delete All Data" to
    /// clear iCloud, which is wrong in This Device Only mode: nothing was
    /// uploaded, so there is nothing in iCloud to remove.
    private var deleteDataNote: String {
        if model.storeMode == .cloud {
            "Delete All Data removes everything here and asks iCloud to remove it from your other devices."
        } else {
            "This device isn’t using iCloud, so Delete All Data removes everything here; nothing was uploaded to delete."
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.lock.isEnabled },
                set: { model.setAppLock(enabled: $0) }
            )) {
                IconRow("Require unlock to open", systemImage: appLockIcon, tint: CairnTheme.positive)
            }
            // Disabled only when it cannot be turned on. If it is already on, the
            // toggle must stay usable so it can always be turned back off.
            .disabled(!model.lock.canAuthenticate && !model.lock.isEnabled)
        } header: {
            Text("Privacy")
        } footer: {
            Text(appLockFooter)
        }
    }

    /// The device's own biometry glyph when there is one.
    private var appLockIcon: String {
        switch model.lock.biometryName {
        case "Face ID": "faceid"
        case "Touch ID": "touchid"
        default: "lock.shield"
        }
    }

    private var appLockFooter: LocalizedStringKey {
        guard model.lock.canAuthenticate else {
            return "Set a device passcode or password to use the app lock; until then it stays off."
        }
        let method = model.lock.biometryName.map { "\($0) or your device passcode" } ?? "your device passcode"
        return "Cairn asks for \(method) when it opens or resumes. The SimpleFIN credential stays in the Keychain."
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
            Text("Exports include every transaction, category, and note. Nothing is uploaded; you choose where it saves.")
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
            Link(destination: URL(string: "https://sehejjain.github.io/cairn/privacy.html")!) {
                IconRow("Privacy Policy", systemImage: "hand.raised.fill", tint: .gray) {
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            Link(destination: URL(string: "https://sehejjain.github.io/cairn/support.html")!) {
                IconRow("Support", systemImage: "questionmark.circle.fill", tint: .gray) {
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
