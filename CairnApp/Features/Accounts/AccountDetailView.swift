import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CairnCore

struct AccountDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    let account: Account
    @State private var feed: TransactionsFeed?
    @State private var searchText = ""
    @State private var historySelection: Int?

    /// The account's total row count, from `fetchCount`, so the hero never has
    /// to materialize the account's whole history.
    private var transactionCount: Int { feed?.sqlCount ?? 0 }

    @State private var showingImporter = false
    @State private var importPayload: ImportPayload?
    @State private var showingAddTransaction = false
    @State private var editingTransaction: LedgerTransaction?
    @State private var transactionToDelete: LedgerTransaction?

    @State private var showingRename = false
    @State private var renameText = ""
    @State private var showingDeleteAccount = false

    private struct ImportPayload: Identifiable {
        let id = UUID()
        let text: String
    }

    init(account: Account) {
        self.account = account
    }

    private var accountFilter: TransactionFilter {
        TransactionFilter(accountID: account.persistentModelID)
    }

    /// Resolves a row snapshot back to its model only when an edit or delete is
    /// actually requested.
    private func model(for row: TransactionRowValue) -> LedgerTransaction? {
        guard let id = row.persistentID else { return nil }
        return modelContext.model(for: id) as? LedgerTransaction
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                summary
                    .cairnAppear()
                if !holdings.isEmpty {
                    holdingsCard
                        .cairnAppear(delay: 0.03)
                }
                // The feed is created on first task; until then there is no
                // count to branch on, so nothing is shown rather than flashing
                // the empty state.
                if let feed {
                    if transactionCount > 1 {
                        historyCard
                            .cairnAppear(delay: 0.05)
                    }
                    if transactionCount == 0 {
                        emptyTransactions
                    } else if !feed.rows.isEmpty {
                        TransactionDayList(
                            sections: feed.sections,
                            showsAccount: false,
                            onReachEnd: { feed.loadMore() },
                            onEdit: account.isManual ? { row in
                                if let model = model(for: row) { editingTransaction = model }
                            } : nil,
                            onDelete: account.isManual ? { row in
                                if let model = model(for: row) { transactionToDelete = model }
                            } : nil
                        )
                        .cairnAppear(delay: 0.1)
                    } else if !searchText.isEmpty {
                        EmptyStateView(
                            systemImage: "magnifyingglass",
                            title: "Nothing matches",
                            message: "Try a different search."
                        )
                    }
                }
            }
            .cairnScreen()
        }
        .cairnCanvas()
        .navigationTitle(account.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $searchText, prompt: "Search this account")
        .toolbar { toolbarContent }
        .task {
            if feed == nil {
                feed = TransactionsFeed(container: model.container, filter: accountFilter)
            }
        }
        .task(id: searchText) {
            try? await Task.sleep(for: SearchDebounce.interval)
            guard !Task.isCancelled else { return }
            var updated = accountFilter
            updated.searchText = SearchDebounce.normalize(searchText)
            feed?.filter = updated
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImportSelection(result)
        }
        .sheet(item: $importPayload) { payload in
            ImportTransactionsSheet(account: account, text: payload.text)
                .cairnLockCover()
        }
        .sheet(isPresented: $showingAddTransaction) {
            TransactionEditSheet(account: account)
                .cairnLockCover()
        }
        .sheet(item: $editingTransaction) { transaction in
            TransactionEditSheet(account: account, transaction: transaction)
                .cairnLockCover()
        }
        .alert(
            "Delete transaction?",
            isPresented: Binding(
                get: { transactionToDelete != nil },
                set: { if !$0 { transactionToDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let transaction = transactionToDelete {
                    let target = transaction
                    transactionToDelete = nil
                    Task { await model.deleteManualTransaction(target) }
                }
            }
            Button("Cancel", role: .cancel) { transactionToDelete = nil }
        } message: {
            Text("This can’t be undone.")
        }
        .alert("Rename Account", isPresented: $showingRename) {
            TextField("Name", text: $renameText)
            Button("Save") {
                let name = renameText
                Task { await model.renameManualAccount(account, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete account?", isPresented: $showingDeleteAccount) {
            Button("Delete", role: .destructive) {
                // Capture identity, dismiss, then delete off-screen: the detail
                // view must never read a model that has been removed.
                let accountID = account.persistentModelID
                dismiss()
                Task { await model.deleteManualAccount(id: accountID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the account and all of its transactions. This can’t be undone.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if account.isManual {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddTransaction = true
                } label: {
                    Label("Add Transaction", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import CSV", systemImage: "square.and.arrow.down")
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            accountOptionsMenu
        }
    }

    private var accountOptionsMenu: some View {
        Menu {
            accountVisibilityToggles
            if account.isManual {
                Divider()
                Button("Rename Account…", systemImage: "pencil") {
                    renameText = account.displayName
                    showingRename = true
                }
                Button("Delete Account…", systemImage: "trash", role: .destructive) {
                    showingDeleteAccount = true
                }
            }
        } label: {
            Label("Account Options", systemImage: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var accountVisibilityToggles: some View {
        Toggle("Include in Net Worth", systemImage: "chart.line.uptrend.xyaxis", isOn: Binding(
            get: { account.includeInNetWorth },
            set: { account.includeInNetWorth = $0; try? modelContext.save() }
        ))
        Toggle("Hide Account", systemImage: "eye.slash", isOn: Binding(
            get: { account.isHidden },
            set: { account.isHidden = $0; try? modelContext.save() }
        ))
    }

    // MARK: - Summary

    private var summary: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    AccountGlyph(account: account, size: 40, onInk: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.institution?.name.nonEmpty ?? sourceLabel)
                            .font(.subheadline.weight(.semibold))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    if !account.includeInNetWorth {
                        StatusPill(text: "Excluded", systemImage: "eye.slash", tint: .white.opacity(0.8))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(account.accountType.isLiability ? "Balance owed" : "Current balance")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                    AmountText(
                        money: displayBalance,
                        font: .cairnHero,
                        colorOverride: .white,
                        deemphasizeFraction: true
                    )
                }

                HStack(spacing: 20) {
                    if account.hasAvailableBalance, account.availableBalance.minorUnits != account.balanceMinorUnits {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.accountType.isLiability ? "Available credit" : "Available")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                            AmountText(
                                money: account.availableBalance,
                                font: .subheadline.weight(.semibold),
                                colorOverride: .white
                            )
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transactions")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                        Text("\(transactionCount)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    Spacer()
                    if let date = account.balanceDate {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("As of")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                            Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption.weight(.medium))
                        }
                    }
                }
            }
        }
    }

    /// The hero figure. A liability is shown as a positive amount because the
    /// label already says "owed"; the stored balance stays negative so net-worth
    /// math subtracts it.
    private var displayBalance: Money {
        guard account.accountType.isLiability else { return account.balance }
        return Money(minorUnits: abs(account.balanceMinorUnits), currency: account.currency)
    }

    private var subtitle: String {
        var parts: [String] = []
        // Wallet data is only ever refreshed on iPhone/iPad; elsewhere say so
        // instead of implying the local device keeps it current.
        if account.isWallet, !WalletAvailability.isSupported {
            parts.append(String(localized: "Updates on your iPhone"))
        }
        parts.append(String(localized: "\(account.accountType.displayName)"))
        if account.currency.code != "USD" || account.currency.isCustom {
            parts.append(String(localized: "\(account.currency.displayLabel)"))
        }
        return parts.joined(separator: " · ")
    }

    /// What the account is "from", shown in the hero header.
    private var sourceLabel: String {
        if account.isWallet { return String(localized: "\(AccountSource.financeKit.displayName)") }
        return account.isManual ? String(localized: "Manual account") : String(localized: "Account")
    }

    // MARK: - History

    private var holdings: [Holding] {
        (account.holdings ?? []).sorted { $0.displayOrder < $1.displayOrder }
    }

    private var holdingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Positions", trailing: "\(holdings.count)")
            RowGroup {
                ForEach(holdings) { holding in
                    HoldingEntry(holding: holding, isLast: holding.persistentModelID == holdings.last?.persistentModelID)
                }
            }
        }
    }

    private var historyCard: some View {
        let series = NetWorthMath.series(account: account, days: 90)
        let change = NetWorthMath.change(in: series)
        let selected = historySelection.flatMap { series.indices.contains($0) ? series[$0] : nil }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("Last 90 days") {
                    if let selected {
                        AmountText(
                            money: Money(minorUnits: selected.balanceMinorUnits, currency: account.currency),
                            font: .callout.weight(.semibold)
                        )
                    } else if let ratio = change.ratio {
                        TrendPill(ratio: ratio, higherIsBad: account.accountType.isLiability)
                    }
                }
                Sparkline(
                    values: series.map { NetWorthMath.doubleValue($0.balanceMinorUnits, currency: account.currency) },
                    tint: AccountGlyphStyle.forAccount(account).tint,
                    selection: $historySelection
                )
                .frame(height: 72)
                .onChange(of: series.count) { _, _ in historySelection = nil }
                .sensoryFeedback(.selection, trigger: historySelection)
                Text(
                    selected.map { "Balance on \($0.date.formatted(date: .abbreviated, time: .omitted))" }
                        ?? changeSentence(change.delta)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            }
        }
        .animation(CairnTheme.Motion.quick, value: historySelection)
    }

    private func changeSentence(_ delta: Int64) -> String {
        if delta == 0 { return "Balance unchanged over the period." }
        let money = Money(minorUnits: abs(delta), currency: account.currency)
        let since = Calendar.current.date(byAdding: .day, value: -90, to: .now)?
            .formatted(date: .abbreviated, time: .omitted) ?? "90 days ago"
        return "\(delta > 0 ? "Up" : "Down") \(money.formatted()) since \(since)."
    }

    private var emptyTransactions: some View {
        EmptyStateView(
            systemImage: emptyStateIcon,
            title: "No transactions yet",
            message: emptyStateMessage,
            actionTitle: emptyActionTitle
        ) {
            if account.isManual {
                showingImporter = true
            } else {
                Task { await model.syncAll(force: true) }
            }
        }
    }

    private var emptyActionTitle: LocalizedStringKey? {
        if account.isWallet { return nil }
        return account.isManual ? "Import CSV" : "Sync Now"
    }

    private var emptyStateIcon: String {
        if account.isWallet { return "wallet.pass" }
        return account.isManual ? "square.and.arrow.down" : "arrow.triangle.2.circlepath"
    }

    private var emptyStateMessage: LocalizedStringKey {
        if account.isWallet {
            return "Wallet activity appears here after Cairn refreshes on your iPhone."
        }
        return account.isManual
            ? "Import a CSV export from your bank or card to fill this account."
            : "Sync to fetch recent activity for this account."
    }

    // MARK: - Import

    private func handleImportSelection(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                    model.banner = "Couldn’t read that file as text."
                    return
                }
                importPayload = ImportPayload(text: text)
            } catch {
                model.banner = "Couldn’t open the file: \(error.localizedDescription)"
            }
        case let .failure(error):
            model.banner = "Import cancelled: \(error.localizedDescription)"
        }
    }
}

/// One holding row plus its trailing hairline, emitted as a single view.
private struct HoldingEntry: View {
    let holding: Holding
    let isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            HoldingRow(holding: holding)
            if !isLast {
                RowDivider()
            }
        }
    }
}

// MARK: - Transaction detail

struct TransactionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var model
    @Query(
        sort: [
            SortDescriptor(\CairnSchemaV1.Category.sortOrder),
            SortDescriptor(\CairnSchemaV1.Category.createdAt),
        ]
    ) private var categories: [CairnSchemaV1.Category]
    @Query(sort: \Tag.name) private var allTags: [Tag]

    let transaction: LedgerTransaction

    @State private var showingNewTag = false
    @State private var showingRuleEditor = false

    private let columns = [GridItem(.adaptive(minimum: 148), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                header
                categoryCard
                optionsCard
                noteCard
                tagsCard
                detailsCard
            }
            .cairnScreen()
        }
        .cairnCanvas()
        .navigationTitle("Transaction")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingRuleEditor = true
                } label: {
                    Label("Create Rule", systemImage: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showingRuleEditor) {
            RuleEditorView(
                prefillPattern: rulePattern,
                prefillCategory: transaction.effectiveCategory
            )
            .cairnLockCover()
        }
        .sensoryFeedback(.selection, trigger: transaction.effectiveCategory?.uuid)
    }

    private var header: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    CategoryBadge(
                        symbolName: transaction.effectiveCategory?.symbolName
                            ?? (transaction.countsAsTransfer ? "arrow.left.arrow.right" : nil),
                        hex: transaction.effectiveCategory?.colorHex,
                        size: 52
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        if transaction.payeeDescription.isEmpty {
                            Text("No description")
                                .font(.title3.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(transaction.payeeDescription)
                                .font(.title3.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 6) {
                            Text(transaction.effectiveDate, format: .dateTime.weekday(.wide).month(.wide).day())
                            if transaction.isPending {
                                StatusPill(text: "Pending", systemImage: "clock", tint: CairnTheme.warning)
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }

                AmountText(
                    money: transaction.amount,
                    showSign: true,
                    font: .cairnHero,
                    colorOverride: transaction.amount.isNegative || transaction.countsAsTransfer ? nil : CairnTheme.positive,
                    deemphasizeFraction: true
                )

                if let account = transaction.account {
                    HStack(spacing: 8) {
                        AccountGlyph(account: account, size: 24)
                        Text(account.displayName)
                            .font(.footnote.weight(.medium))
                        if let institution = account.institution?.name, !institution.isEmpty {
                            Text("·").foregroundStyle(.tertiary)
                            Text(institution)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var categoryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("Category", subtitle: categorySubtitle) {
                    HStack(spacing: 12) {
                        if transaction.effectiveCategory != nil {
                            Button("Create Rule") { showingRuleEditor = true }
                                .font(.subheadline.weight(.medium))
                        }
                        if transaction.isCategorizedByUser {
                            Button("Reset") {
                                withAnimation(CairnTheme.Motion.quick) {
                                    transaction.userCategory = nil
                                    touch()
                                }
                            }
                            .font(.subheadline.weight(.medium))
                        }
                    }
                }

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(categories.filter {
                        !$0.isArchived || $0.uuid == transaction.effectiveCategory?.uuid
                    }) { category in
                        let selected = transaction.effectiveCategory?.uuid == category.uuid
                        Button {
                            select(category)
                        } label: {
                            categoryChip(category, selected: selected)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func categoryChip(_ category: CairnSchemaV1.Category, selected: Bool) -> some View {
        let tint = CairnTheme.color(hex: category.colorHex)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 9) {
            Image(systemName: category.symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? Color.white : tint)
                .frame(width: 24, height: 24)
                .background(
                    selected ? Color.white.opacity(0.22) : tint.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            Text(category.name)
                .font(.subheadline.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(CairnTheme.surfaceInset), in: shape)
        .overlay(shape.strokeBorder(selected ? Color.clear : CairnTheme.outline, lineWidth: 1))
        .contentShape(shape)
        .animation(CairnTheme.Motion.quick, value: selected)
    }

    private var categorySubtitle: LocalizedStringKey {
        if transaction.isCategorizedByUser {
            return "Set by you. Automatic rules won't change it."
        }
        if transaction.autoCategory != nil {
            return "Set automatically \(autoSourceLabel). Tap to override."
        }
        return "Choose a category. Cairn remembers it for this merchant."
    }

    private func select(_ category: CairnSchemaV1.Category) {
        withAnimation(CairnTheme.Motion.quick) {
            if transaction.userCategory?.uuid == category.uuid {
                transaction.userCategory = nil
            } else {
                transaction.userCategory = category
                // Choosing a real category means this should be counted as
                // spending, not money movement. "Transfers" is the exception.
                transaction.isTransfer = category.name == "Transfers"
                transaction.isTransferUserSet = true
            }
            touch()
        }
        model.propagateUserCategory(of: transaction.persistentModelID)
    }

    private var optionsCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                Toggle(isOn: Binding(
                    get: { transaction.isTransfer },
                    set: {
                        transaction.isTransfer = $0
                        transaction.isTransferUserSet = true
                        touch()
                        Task { await model.refreshRecurring() }
                    }
                )) {
                    IconRow(
                        "Transfer",
                        subtitle: "Money moving between your own accounts. Left out of spending.",
                        systemImage: "arrow.left.arrow.right",
                        tint: Color(red: 0.20, green: 0.68, blue: 0.90)
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                RowDivider(leadingInset: 57)

                Toggle(isOn: Binding(
                    get: { transaction.isIgnored },
                    set: { transaction.isIgnored = $0; touch(); Task { await model.refreshRecurring() } }
                )) {
                    IconRow("Ignore", subtitle: "Hide from insights and totals entirely.", systemImage: "eye.slash", tint: .gray)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var noteCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("Note")
                TextField("Add a note", text: noteBinding, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(
                        CairnTheme.surfaceInset,
                        in: RoundedRectangle(cornerRadius: CairnTheme.controlRadius, style: .continuous)
                    )
            }
        }
    }

    private var tagsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    "Tags",
                    subtitle: assignedTags.isEmpty ? "Label this transaction. Tags are searchable." : nil
                )
                if !assignedTags.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(assignedTags) { tag in
                            Button { toggleTag(tag) } label: {
                                TagChip(name: tag.name, colorHex: tag.colorHex, showsRemove: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Menu {
                    ForEach(allTags) { tag in
                        Button {
                            toggleTag(tag)
                        } label: {
                            Label(
                                tag.name,
                                systemImage: isAssigned(tag) ? "checkmark" : "tag"
                            )
                        }
                    }
                    if !allTags.isEmpty { Divider() }
                    Button("New Tag…", systemImage: "plus") { showingNewTag = true }
                } label: {
                    Label("Add Tag", systemImage: "plus.circle")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
        .sheet(isPresented: $showingNewTag) {
            TagEditorView { tag in assignTag(tag) }
                .cairnLockCover()
        }
    }

    private var assignedTags: [Tag] {
        (transaction.tags ?? []).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func isAssigned(_ tag: Tag) -> Bool {
        (transaction.tags ?? []).contains { $0.persistentModelID == tag.persistentModelID }
    }

    private func toggleTag(_ tag: Tag) {
        var current = transaction.tags ?? []
        if let index = current.firstIndex(where: { $0.persistentModelID == tag.persistentModelID }) {
            current.remove(at: index)
        } else {
            current.append(tag)
        }
        transaction.tags = current
        touch()
    }

    private func assignTag(_ tag: Tag) {
        guard !isAssigned(tag) else { return }
        var current = transaction.tags ?? []
        current.append(tag)
        transaction.tags = current
        touch()
    }

    /// The cleaned merchant name makes a better rule pattern than the raw
    /// description, which usually carries a store number or city.
    private var rulePattern: String {
        transaction.normalizedMerchant.isEmpty
            ? transaction.payeeDescription
            : transaction.normalizedMerchant
    }

    private var detailsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("Details")
                detailRow("Posted", transaction.postedDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Pending")
                if let transacted = transaction.transactedAt {
                    detailRow("Transacted", transacted.formatted(date: .abbreviated, time: .shortened))
                }
                detailRow("Institution", transaction.account?.institution?.name ?? "—")
                if transaction.bankTransactionID.hasPrefix("manual-") {
                    detailRow("Source", "Manual")
                } else if transaction.bankTransactionID.hasPrefix("import-") {
                    detailRow("Source", "CSV import")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Transaction ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(transaction.bankTransactionID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private var autoSourceLabel: String {
        switch transaction.autoCategorySource {
        case "rule": "by a rule"
        case "memory": "from your history"
        case "similarMerchant": "from a similar merchant"
        case "heuristic": "by automatic detection"
        case "appleIntelligence", "model": "by Apple Intelligence"
        default: "automatically"
        }
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { transaction.note ?? "" },
            set: { transaction.note = $0.isEmpty ? nil : $0; touch() }
        )
    }

    private func touch() {
        transaction.reviewedAt = .now
        transaction.modifiedAt = .now
        try? modelContext.save()
    }
}
