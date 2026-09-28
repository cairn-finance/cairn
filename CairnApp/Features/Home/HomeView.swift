import SwiftUI
import SwiftData
import CairnCore

/// The landing screen: net worth up top, then every account grouped by
/// institution. Tapping the hero opens the full net-worth history.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \Institution.name) private var institutions: [Institution]
    @Query(
        filter: #Predicate<Account> { $0.isHidden == false },
        sort: [SortDescriptor(\Account.displayOrder)]
    )
    private var accounts: [Account]
    @Query private var settings: [AppSettings]
    @Query private var categories: [CairnSchemaV4.Category]
    @Query private var budgetSettings: [CategoryBudget]
    @Query private var commitments: [ConfirmedCommitment]

    @State private var showingConnect = false
    @State private var showingManualAccount = false
    @State private var budgetTransactions: [BudgetTransaction] = []
    @State private var budgetReloadToken = 0
    @State private var didLoadBudgetSummary = false
    @State private var budgetLoadFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                if model.isOffline {
                    OfflineNoticeView()
                        .cairnAppear()
                }
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

                    SyncIssueCard()

                    syncStatus
                        .cairnAppear(delay: 0.05)

                    planningSection
                        .cairnAppear(delay: 0.08)

                    ScreenSectionHeader(
                        "Accounts",
                        subtitle: "Balances grouped by where they are held."
                    )
                    institutionsSection
                        .cairnAppear(delay: 0.1)
                }
            }
            .cairnScreen(maxWidth: CairnTheme.dashboardMaxWidth)
        }
        .cairnScrollEdge()
        .cairnCanvas()
        .navigationTitle("Home")
        .toolbar { toolbarContent }
        .task(id: budgetReloadKey) { await loadBudgetSummary() }
        .task {
            for await _ in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                budgetReloadToken &+= 1
            }
        }
        .refreshable { await model.syncAll(force: true) }
        .sheet(isPresented: $showingConnect) {
            AddConnectionSheet { showingConnect = false }
                .cairnLockCover()
        }
        .sheet(isPresented: $showingManualAccount) {
            ManualAccountSheet()
                .cairnLockCover()
        }
    }

    // MARK: - Sections

    private var planningSection: some View {
        VStack(alignment: .leading, spacing: CairnTheme.Spacing.m) {
            ScreenSectionHeader(
                "Planning",
                subtitle: "What this month is committed to and what remains."
            )

            DashboardGrid(minimumColumnWidth: 340) {
                NavigationLink {
                    BudgetView(
                        initialMonthKey: budgetMonthKey,
                        initialCurrencyCode: budgetCurrency.code
                    )
                } label: {
                    budgetSummaryCard
                }
                .buttonStyle(.pressableCard)

                if !homeRecurring.isEmpty {
                    NavigationLink {
                        RecurringView()
                    } label: {
                         RecurringSummaryCard(series: homeRecurring, currency: homeCurrency, confirmedCount: commitments.filter { $0.state == .active && $0.currency.code == homeCurrency.code }.count)
                    }
                    .buttonStyle(.pressableCard)
                }
            }
        }
    }

    private var budgetCurrency: Currency {
        accounts.first(where: { $0.currency.code == homeCurrency.code })?.currency
            ?? accounts.first?.currency
            ?? homeCurrency
    }

    private var budgetMonthKey: String {
        BudgetCalculator.monthKey(for: .now, timeZone: budgetTimeZone)
    }

    private var budgetTimeZone: TimeZone {
        budgetSettings
            .filter { $0.currencyCode == budgetCurrency.code }
            .sorted {
                if $0.monthKey != $1.monthKey { return $0.monthKey < $1.monthKey }
                return $0.uuid.uuidString < $1.uuid.uuidString
            }
            .compactMap { TimeZone(identifier: $0.timeZoneIdentifier) }
            .first ?? .current
    }

    private var budgetReloadKey: String {
        let editStamp = budgetSettings.map(\.modifiedAt).max()?.timeIntervalSince1970 ?? 0
        let accountStamp = accounts.filter { $0.currency.code == budgetCurrency.code }
            .map(\.bankAccountID).sorted().joined(separator: ",")
        let categoryStamp = categories.map { "\($0.uuid.uuidString):\($0.name):\($0.isArchived)" }
            .joined(separator: ",")
        return "\(budgetReloadToken)-\(budgetMonthKey)-\(budgetCurrency.code)-\(editStamp)-\(accountStamp)-\(categoryStamp)"
    }

    private var budgetSnapshot: BudgetSnapshot? {
        guard didLoadBudgetSummary, !budgetLoadFailed else { return nil }
        let categoryValues = categories.map {
            BudgetCategory(
                uuid: $0.uuid,
                name: $0.name,
                colorHex: $0.colorHex,
                symbolName: $0.symbolName,
                sortOrder: $0.sortOrder,
                isArchived: $0.isArchived
            )
        }
        let settingValues = budgetSettings.map {
            BudgetSetting(
                uuid: $0.uuid,
                categoryUUID: $0.categoryUUID,
                currency: $0.currency,
                monthKey: $0.monthKey,
                amountMinorUnits: $0.amountMinorUnits,
                isMonthOverride: $0.isMonthOverride,
                isEnabled: $0.isEnabled,
                timeZoneIdentifier: $0.timeZoneIdentifier,
                modifiedAt: $0.modifiedAt
            )
        }
        return BudgetCalculator.snapshot(
            transactions: budgetTransactions,
            categories: categoryValues,
            settings: settingValues,
            monthKey: budgetMonthKey,
            currency: budgetCurrency,
            timeZone: budgetTimeZone
        )
    }

    private var budgetSummaryCard: some View {
        Card(padding: 14) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    budgetSummaryHeader
                    budgetSummaryDetails
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        budgetSummaryHeader
                        budgetSummaryDetails
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                        .padding(.top, 7)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var budgetSummaryHeader: some View {
        HStack(alignment: .top, spacing: 7) {
            SettingsIcon(systemImage: "chart.pie.fill", tint: CairnTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Monthly budget")
                    .font(.subheadline.weight(.semibold))
                if Set(accounts.map(\.currency.code)).count > 1 {
                    Text(budgetCurrency.code)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var budgetSummaryDetails: some View {
        if budgetLoadFailed {
            Text("Spending unavailable. Open Budget to retry.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let summary = budgetSnapshot {
            if summary.lines.contains(where: { $0.plannedMinorUnits != nil }) {
                plannedBudgetDetails(summary)
            } else {
                noLimitsDetails(summary)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Loading budget")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func plannedBudgetDetails(_ summary: BudgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            budgetStatusText(summary)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            let plannedSpent = Money(
                minorUnits: summary.budgetedSpentMinorUnits,
                currency: summary.currency
            ).formatted()
            let planned = Money(
                minorUnits: summary.plannedMinorUnits,
                currency: summary.currency
            ).formatted()
            Text("\(plannedSpent) of \(planned) planned")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if summary.plannedMinorUnits > 0 {
                ProgressView(value: budgetProgress(summary))
                    .tint(summary.remainingMinorUnits < 0 ? CairnTheme.warning : CairnTheme.accent)
                    .accessibilityLabel("Monthly budget progress")
                    .accessibilityValue(Text("\(plannedSpent) of \(planned) planned"))
            }

            if summary.unbudgetedMinorUnits != 0 {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spending outside limits")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        budgetUnbudgetedAmount(summary)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Spending outside limits")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        budgetUnbudgetedAmount(summary)
                    }
                }
            }
        }
    }

    private func budgetUnbudgetedAmount(_ summary: BudgetSnapshot) -> some View {
        AmountText(
            money: Money(
                minorUnits: summary.unbudgetedMinorUnits,
                currency: summary.currency
            ),
            font: .caption.weight(.medium)
        )
    }

    private func noLimitsDetails(_ summary: BudgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No category limits yet")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(Money(minorUnits: summary.spentMinorUnits, currency: summary.currency).formatted()) net spending this month")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Set category limits")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CairnTheme.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func budgetStatusText(_ summary: BudgetSnapshot) -> Text {
        let remaining = summary.remainingMinorUnits
        let amount = Money(
            minorUnits: MinorUnits.absClamped(remaining),
            currency: summary.currency
        ).formatted()
        return remaining < 0
            ? Text("\(amount) over planned limits")
            : Text("\(amount) left in planned categories")
    }

    private func budgetProgress(_ summary: BudgetSnapshot) -> Double {
        guard summary.plannedMinorUnits > 0 else { return 0 }
        return min(
            1,
            max(0, Double(summary.budgetedSpentMinorUnits) / Double(summary.plannedMinorUnits))
        )
    }

    private func loadBudgetSummary() async {
        didLoadBudgetSummary = false
        budgetLoadFailed = false
        let visible = accounts.filter { $0.currency.code == budgetCurrency.code }
        guard !visible.isEmpty,
              let start = BudgetCalculator.startOfMonth(budgetMonthKey, timeZone: budgetTimeZone) else {
            budgetTransactions = []
            didLoadBudgetSummary = true
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = budgetTimeZone
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        let scopes = visible.map { BudgetAccountScope(bankAccountID: $0.bankAccountID) }
        let container = model.container
        let fetcher = await Task.detached(priority: .utility) {
            BudgetFetcher(modelContainer: container)
        }.value
        do {
            let result = try await fetcher.budgetTransactions(scopes: scopes, from: start, to: end)
            guard !Task.isCancelled else { return }
            budgetTransactions = result
        } catch {
            guard !Task.isCancelled else { return }
            budgetTransactions = []
            budgetLoadFailed = true
        }
        didLoadBudgetSummary = true
    }

    private var syncStatus: some View {
        HStack(spacing: 10) {
            switch model.syncState {
            case .syncing:
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            case let .failed(message):
                if model.syncProblemIsJustOffline {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(CairnTheme.warning)
                    Text("Sync paused while offline")
                        .accessibilityHint(message)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(CairnTheme.warning)
                    Text("Last sync had a problem")
                        .accessibilityHint(message)
                }
            case let .waiting(title, detail, _):
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Text(title)
                    .accessibilityHint(detail)
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
            if model.remainingBudget < SyncEngine.dailyRequestLimit / 4 {
                StatusPill(text: "^[\(model.remainingBudget) sync](inflect: true) left today", tint: CairnTheme.warning)
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

    /// The currency the net-worth hero leads with, so the recurring summary
    /// matches it rather than mixing currencies.
    private var homeCurrency: Currency {
        NetWorthMath.primaryCurrency(
            totals: NetWorthMath.totals(accounts: accounts),
            home: NetWorthMath.homeCurrency(settings: settings)
        )
    }

    private var homeRecurring: [RecurringSeries] {
        model.recurringSeries.filter { $0.currency.code == homeCurrency.code }
    }

    private var institutionsSection: some View {
        VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
            ForEach(institutions) { institution in
                let institutionAccounts = accounts.filter {
                    $0.institution?.persistentModelID == institution.persistentModelID
                }
                if !institutionAccounts.isEmpty {
                    accountGroup(
                        title: institution.name.isEmpty ? "Institution" : LocalizedStringKey(institution.name),
                        trailing: institutionTrailing(institution),
                        accounts: institutionAccounts
                    )
                }
            }

            if !walletAccounts.isEmpty {
                accountGroup(title: "Apple Wallet", trailing: walletTrailing, accounts: walletAccounts)
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

    private func accountGroup(title: LocalizedStringKey, trailing: String?, accounts: [Account]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title, trailing: trailing)
            RowGroup {
                ForEach(accounts) { account in
                    AccountGroupEntry(
                        account: account,
                        isLast: account.persistentModelID == accounts.last?.persistentModelID
                    )
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
                        .accessibilityHidden(true)
                    Text("Welcome to Cairn")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Connect a bank, read Apple Wallet, or add an account by hand. Everything stays on your devices.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SetupActions()
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
                    Label("Add a Connection", systemImage: "plus")
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
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            SyncButton()
        }
    }

    private var manualAccounts: [Account] {
        accounts.filter { $0.institution == nil && $0.source == .manual }
    }

    private var walletAccounts: [Account] {
        accounts.filter { $0.source == .financeKit }
    }

    /// Wallet data can only be refreshed on iPhone/iPad, so a Mac shows when it
    /// arrived rather than a live sync. A note keeps it from looking stale.
    private var walletTrailing: String? {
        #if os(macOS)
        return "Updates on your iPhone"
        #else
        guard let date = walletAccounts.compactMap(\.lastSyncedAt).max() else { return nil }
        return date.formatted(.relative(presentation: .named))
        #endif
    }
}

/// One account row plus its trailing hairline, emitted as a single view so the
/// list never has to build two elements to place a divider.
private struct AccountGroupEntry: View {
    let account: Account
    let isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                AccountDetailView(account: account)
            } label: {
                AccountRow(account: account)
            }
            .buttonStyle(.plain)
            if !isLast {
                RowDivider()
            }
        }
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
                    if let selectedPoint {
                        Text(selectedPoint.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .contentTransition(.opacity)
                    } else {
                        Text("Net worth")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .contentTransition(.opacity)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .accessibilityHidden(true)
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
