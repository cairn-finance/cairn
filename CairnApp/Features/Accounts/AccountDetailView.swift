import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CairnCore

struct AccountDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var model

    let account: Account
    @Query private var transactions: [LedgerTransaction]

    @State private var showingImporter = false
    @State private var importPayload: ImportPayload?
    @State private var searchText = ""
    @State private var historySelection: Int?

    private struct ImportPayload: Identifiable {
        let id = UUID()
        let text: String
    }

    init(account: Account) {
        self.account = account
        let bankID = account.bankAccountID
        _transactions = Query(
            filter: #Predicate { $0.accountIDIndex == bankID },
            sort: [SortDescriptor(\LedgerTransaction.postedDate, order: .reverse)]
        )
    }

    /// Pending transactions have no posted date, so sort by effective date to
    /// keep them at the top.
    private var visibleTransactions: [LedgerTransaction] {
        let base = searchText.isEmpty
            ? transactions
            : transactions.filter {
                $0.payeeDescription.localizedStandardContains(searchText)
                    || ($0.effectiveCategory?.name.localizedStandardContains(searchText) ?? false)
                    || ($0.note?.localizedStandardContains(searchText) ?? false)
            }
        return base.sorted { $0.effectiveDate > $1.effectiveDate }
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
                if transactions.count > 1 {
                    historyCard
                        .cairnAppear(delay: 0.05)
                }
                if transactions.isEmpty {
                    emptyTransactions
                } else if visibleTransactions.isEmpty {
                    EmptyStateView(systemImage: "magnifyingglass", title: "Nothing matches", message: "Try a different search.")
                } else {
                    TransactionDayList(transactions: visibleTransactions, showsAccount: false)
                        .cairnAppear(delay: 0.1)
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
        .toolbar {
            if account.isManual {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import CSV", systemImage: "square.and.arrow.down")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Include in Net Worth", systemImage: "chart.line.uptrend.xyaxis", isOn: Binding(
                        get: { account.includeInNetWorth },
                        set: { account.includeInNetWorth = $0; try? modelContext.save() }
                    ))
                    Toggle("Hide Account", systemImage: "eye.slash", isOn: Binding(
                        get: { account.isHidden },
                        set: { account.isHidden = $0; try? modelContext.save() }
                    ))
                } label: {
                    Label("Account Options", systemImage: "ellipsis.circle")
                }
            }
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
        }
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
                            AmountText(money: account.availableBalance, font: .subheadline.weight(.semibold), colorOverride: .white)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transactions")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                        Text("\(transactions.count)")
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
            parts.append("Updates on your iPhone")
        }
        parts.append(account.accountType.displayName)
        if account.currency.code != "USD" || account.currency.isCustom { parts.append(account.currency.displayLabel) }
        return parts.joined(separator: " · ")
    }

    /// What the account is "from", shown in the hero header.
    private var sourceLabel: String {
        if account.isWallet { return AccountSource.financeKit.displayName }
        return account.isManual ? "Manual account" : "Account"
    }

    // MARK: - History

    private var holdings: [Holding] {
        (account.holdings ?? []).sorted { $0.displayOrder < $1.displayOrder }
    }

    private var holdingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Positions", trailing: "\(holdings.count)")
            RowGroup {
                ForEach(Array(holdings.enumerated()), id: \.element.persistentModelID) { index, holding in
                    HoldingRow(holding: holding)
                    if index < holdings.count - 1 { RowDivider() }
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
        return "\(delta > 0 ? "Up" : "Down") \(money.formatted()) since \(Calendar.current.date(byAdding: .day, value: -90, to: .now)?.formatted(date: .abbreviated, time: .omitted) ?? "90 days ago")."
    }

    private var emptyTransactions: some View {
        EmptyStateView(
            systemImage: emptyStateIcon,
            title: "No transactions yet",
            message: emptyStateMessage,
            actionTitle: account.isManual ? "Import CSV" : nil
        ) {
            showingImporter = true
        }
    }

    private var emptyStateIcon: String {
        if account.isWallet { return "wallet.pass" }
        return account.isManual ? "square.and.arrow.down" : "arrow.triangle.2.circlepath"
    }

    private var emptyStateMessage: String {
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

// MARK: - Transaction detail

struct TransactionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var model
    @Query(sort: \CairnSchemaV1.Category.sortOrder) private var categories: [CairnSchemaV1.Category]

    let transaction: LedgerTransaction

    private let columns = [GridItem(.adaptive(minimum: 148), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                header
                categoryCard
                optionsCard
                noteCard
                detailsCard
            }
            .cairnScreen()
        }
        .cairnCanvas()
        .navigationTitle("Transaction")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
                        Text(transaction.payeeDescription.isEmpty ? "No description" : transaction.payeeDescription)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
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

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(categories.filter { !$0.isArchived }) { category in
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
                .background(selected ? Color.white.opacity(0.22) : tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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

    private var categorySubtitle: String {
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
                        model.refreshRecurring()
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
                    set: { transaction.isIgnored = $0; touch(); model.refreshRecurring() }
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
                    .background(CairnTheme.surfaceInset, in: RoundedRectangle(cornerRadius: CairnTheme.controlRadius, style: .continuous))
            }
        }
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
                if transaction.isImported {
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
