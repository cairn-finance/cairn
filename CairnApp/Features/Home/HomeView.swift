import SwiftUI
import SwiftData
import CairnCore

/// The landing screen: net worth up top, then every account grouped by
/// institution. Tapping the hero opens the full net-worth history.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Institution.name) private var institutions: [Institution]
    @Query(
        filter: #Predicate<Account> { $0.isHidden == false },
        sort: [SortDescriptor(\Account.displayOrder)]
    )
    private var accounts: [Account]
    @Query private var settings: [AppSettings]

    @State private var showingConnect = false
    @State private var showingManualAccount = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                if accounts.isEmpty {
                    emptyState
                } else {
                    NavigationLink {
                        NetWorthView()
                    } label: {
                        NetWorthHero(accounts: accounts, settings: settings)
                    }
                    .buttonStyle(.pressableCard)
                    .cairnAppear()

                    syncStatus
                        .cairnAppear(delay: 0.05)

                    institutionsSection
                        .cairnAppear(delay: 0.1)
                }
            }
            .cairnScreen()
        }
        .cairnCanvas()
        .navigationTitle("Home")
        .toolbar { toolbarContent }
        .refreshable { await model.syncAll(force: true) }
        .sheet(isPresented: $showingConnect) {
            ConnectBankSheet { showingConnect = false }
        }
        .sheet(isPresented: $showingManualAccount) {
            ManualAccountSheet()
        }
    }

    // MARK: - Sections

    private var syncStatus: some View {
        HStack(spacing: 10) {
            switch model.syncState {
            case .syncing:
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(CairnTheme.warning)
                Text("Last sync had a problem")
                    .accessibilityHint(message)
            case let .waiting(message):
                Image(systemName: "key.icloud")
                    .foregroundStyle(.secondary)
                Text("Waiting for iCloud Keychain")
                    .accessibilityHint(message)
            case .idle, .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(CairnTheme.positive)
                if let date = lastSync {
                    Text("Updated \(date, format: .relative(presentation: .named))")
                } else {
                    Text("Not synced yet")
                }
            }
            Spacer()
            if model.syncState.hasDetails {
                NavigationLink {
                    SyncDiagnosticsView()
                } label: {
                    Text("Details")
                        .font(.footnote.weight(.semibold))
                }
            } else if model.remainingBudget < SyncEngine.dailyRequestLimit / 4 {
                StatusPill(text: "\(model.remainingBudget) syncs left today", tint: CairnTheme.warning)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .animation(CairnTheme.Motion.quick, value: model.syncState)
    }

    private var lastSync: Date? {
        institutions.compactMap(\.lastSyncDate).max() ?? accounts.compactMap(\.lastSyncedAt).max()
    }

    private var institutionsSection: some View {
        VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
            ForEach(institutions) { institution in
                let institutionAccounts = accounts.filter {
                    $0.institution?.persistentModelID == institution.persistentModelID
                }
                if !institutionAccounts.isEmpty {
                    accountGroup(
                        title: institution.name.isEmpty ? "Institution" : institution.name,
                        trailing: institutionTrailing(institution),
                        accounts: institutionAccounts
                    )
                }
            }

            if !manualAccounts.isEmpty {
                accountGroup(title: "Manual accounts", trailing: nil, accounts: manualAccounts)
            }
        }
    }

    private func institutionTrailing(_ institution: Institution) -> String? {
        if institution.lastSyncError != nil { return "Needs attention" }
        guard let date = institution.lastSyncDate else { return "Not synced yet" }
        return date.formatted(.relative(presentation: .named))
    }

    private func accountGroup(title: String, trailing: String?, accounts: [Account]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title, trailing: trailing)
            RowGroup {
                ForEach(Array(accounts.enumerated()), id: \.element.persistentModelID) { index, account in
                    NavigationLink {
                        AccountDetailView(account: account)
                    } label: {
                        AccountRow(account: account)
                    }
                    .buttonStyle(.plain)
                    if index < accounts.count - 1 {
                        RowDivider()
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: CairnTheme.Spacing.l) {
            HeroCard {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(CairnTheme.inkGlow)
                    Text("Welcome to Cairn")
                        .font(.title2.weight(.semibold))
                    Text("Connect a bank through SimpleFIN or add an account by hand. Everything stays on your devices.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                showingConnect = true
            } label: {
                Label("Connect a Bank", systemImage: "building.columns")
            }
            .buttonStyle(.cairnProminent)
            Button {
                showingManualAccount = true
            } label: {
                Label("Add a Manual Account", systemImage: "square.and.pencil")
            }
            .buttonStyle(.cairnSecondary)
        }
        .padding(.top, 8)
        .cairnAppear()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    showingConnect = true
                } label: {
                    Label("Connect a Bank", systemImage: "building.columns")
                }
                Button {
                    showingManualAccount = true
                } label: {
                    Label("Add Manual Account", systemImage: "square.and.pencil")
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            SyncButton()
        }
    }

    private var manualAccounts: [Account] {
        accounts.filter { $0.institution == nil }
    }
}

/// The sync toolbar button, which spins its arrows while a sync runs.
struct SyncButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Task { await model.syncAll(force: true) }
        } label: {
            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, isActive: model.syncState == .syncing)
        }
        .disabled(model.syncState == .syncing)
        .sensoryFeedback(.success, trigger: model.syncState == .success)
    }
}

/// The net-worth hero on Home: the figure, the 30-day change, and a sparkline.
struct NetWorthHero: View {
    let accounts: [Account]
    let settings: [AppSettings]

    @State private var selectedIndex: Int?

    private var totals: [CurrencyTotal] { NetWorthMath.totals(accounts: accounts) }
    private var currency: Currency {
        NetWorthMath.primaryCurrency(totals: totals, home: NetWorthMath.homeCurrency(settings: settings))
    }
    private var total: Int64 {
        totals.first { $0.currency.code == currency.code }?.totalMinorUnits ?? 0
    }
    private var series: [(date: Date, balanceMinorUnits: Int64)] {
        NetWorthMath.series(accounts: accounts, currency: currency, days: 30)
    }
    private var selectedPoint: (date: Date, balanceMinorUnits: Int64)? {
        guard let selectedIndex, series.indices.contains(selectedIndex) else { return nil }
        return series[selectedIndex]
    }

    var body: some View {
        let change = NetWorthMath.change(in: series)
        let split = NetWorthMath.assetsAndLiabilities(accounts: accounts, currency: currency)
        let shown = selectedPoint?.balanceMinorUnits ?? total

        HeroCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(selectedPoint.map { $0.date.formatted(date: .abbreviated, time: .omitted) } ?? "Net worth")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.opacity)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.5))
                }

                AmountText(
                    money: Money(minorUnits: shown, currency: currency),
                    font: .cairnHero,
                    colorOverride: .white,
                    deemphasizeFraction: true
                )

                HStack(spacing: 8) {
                    if let selected = selectedPoint {
                        Text("Balance on \(selected.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        if let ratio = change.ratio {
                            TrendPill(ratio: ratio, higherIsBad: false, onInk: true)
                        }
                        Text(changeText(change.delta))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                if series.count > 2 {
                    Sparkline(
                        values: series.map { NetWorthMath.doubleValue($0.balanceMinorUnits, currency: currency) },
                        tint: CairnTheme.inkGlow,
                        lineWidth: 2,
                        selection: $selectedIndex
                    )
                    .frame(height: 56)
                    .onChange(of: series.count) { _, _ in selectedIndex = nil }
                    .sensoryFeedback(.selection, trigger: selectedIndex)
                }

                HStack(spacing: 20) {
                    heroMetric("Assets", Money(minorUnits: split.assets, currency: currency))
                    heroMetric("Liabilities", Money(minorUnits: -split.liabilities, currency: currency))
                    if totals.count > 1 {
                        Spacer()
                        Text("+\(totals.count - 1) more currenc\(totals.count == 2 ? "y" : "ies")")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .animation(CairnTheme.Motion.quick, value: selectedIndex)
    }

    private func heroMetric(_ title: String, _ money: Money) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
            AmountText(money: money, font: .subheadline.weight(.semibold), colorOverride: .white)
        }
    }

    private func changeText(_ delta: Int64) -> String {
        let money = Money(minorUnits: delta, currency: currency)
        if delta == 0 { return "No change in 30 days" }
        return "\(delta > 0 ? "+" : "")\(money.formatted()) in 30 days"
    }
}

/// The "Connect a bank" form in a sheet, used from Home and Settings.
struct ConnectBankSheet: View {
    var onConnected: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ConnectBankView(onConnected: onConnected)
                    .padding(CairnTheme.Spacing.l)
                    .frame(maxWidth: CairnTheme.screenMaxWidth)
                    .frame(maxWidth: .infinity)
            }
            .cairnCanvas()
            .navigationTitle("Connect a Bank")
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
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }
}
