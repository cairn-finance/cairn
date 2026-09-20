import SwiftUI
import SwiftData
import CairnCore

/// Every transaction across every account, with search and one-tap filters.
struct TransactionsView: View {
    @Query(sort: [SortDescriptor(\LedgerTransaction.postedDate, order: .reverse)])
    private var allTransactions: [LedgerTransaction]
    @Query(
        sort: [
            SortDescriptor(\CairnSchemaV1.Category.sortOrder),
            SortDescriptor(\CairnSchemaV1.Category.createdAt),
        ]
    )
    private var categories: [CairnSchemaV1.Category]
    @Query(sort: \Tag.name)
    private var tags: [Tag]
    @Query(sort: [SortDescriptor(\Account.displayOrder)])
    private var accounts: [Account]

    @State private var searchText = ""
    @State private var quickFilter: QuickFilter = .all
    @State private var categoryFilter: CairnSchemaV1.Category?
    @State private var accountFilter: Account?
    @State private var tagFilter: Tag?

    enum QuickFilter: String, CaseIterable, Identifiable {
        case all, spending, income, pending, uncategorized
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .spending: "Spending"
            case .income: "Income"
            case .pending: "Pending"
            case .uncategorized: "Needs category"
            }
        }
        var systemImage: String? {
            switch self {
            case .all: nil
            case .spending: "arrow.up.right"
            case .income: "arrow.down.left"
            case .pending: "clock"
            case .uncategorized: "questionmark.circle"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                filterBar
                if filtered.isEmpty {
                    EmptyStateView(
                        systemImage: allTransactions.isEmpty ? "list.bullet.rectangle" : "magnifyingglass",
                        title: allTransactions.isEmpty ? "No activity yet" : "Nothing matches",
                        message: emptyMessage,
                        actionTitle: hasAnyFilter ? "Clear filters" : nil
                    ) {
                        clearFilters()
                    }
                } else {
                    TransactionDayList(transactions: filtered, showsMonthHeaders: true)
                }
            }
            .cairnScreen()
            .animation(CairnTheme.Motion.standard, value: filtered.count)
        }
        .cairnCanvas()
        .navigationTitle("Activity")
        .searchable(text: $searchText, prompt: "Merchant, note, tag, or category")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                filtersMenu
            }
        }
    }

    // MARK: - Filters

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(QuickFilter.allCases) { filter in
                    Button {
                        withAnimation(CairnTheme.Motion.quick) { quickFilter = filter }
                    } label: {
                        Chip(title: filter.title, systemImage: filter.systemImage, isSelected: quickFilter == filter)
                    }
                    .buttonStyle(.plain)
                }
                if let categoryFilter {
                    activeFilterChip(categoryFilter.name, systemImage: categoryFilter.symbolName, tint: CairnTheme.color(hex: categoryFilter.colorHex)) {
                        self.categoryFilter = nil
                    }
                }
                if let accountFilter {
                    activeFilterChip(accountFilter.displayName, systemImage: "building.columns", tint: CairnTheme.accent) {
                        self.accountFilter = nil
                    }
                }
                if let tagFilter {
                    activeFilterChip(tagFilter.name, systemImage: "tag.fill", tint: CairnTheme.color(hex: tagFilter.colorHex)) {
                        self.tagFilter = nil
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: quickFilter)
    }

    private func activeFilterChip(_ title: String, systemImage: String, tint: Color, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.caption.weight(.semibold))
                Text(title).font(.subheadline.weight(.semibold))
                Image(systemName: "xmark").font(.caption2.weight(.bold)).opacity(0.7)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private var filtersMenu: some View {
        Menu {
            Picker("Category", selection: $categoryFilter) {
                Text("All Categories").tag(CairnSchemaV1.Category?.none)
                ForEach(categories.filter { !$0.isArchived }) { category in
                    Label(category.name, systemImage: category.symbolName).tag(CairnSchemaV1.Category?.some(category))
                }
            }
            .pickerStyle(.menu)
            Picker("Account", selection: $accountFilter) {
                Text("All Accounts").tag(Account?.none)
                ForEach(accounts) { account in
                    Text(account.displayName).tag(Account?.some(account))
                }
            }
            .pickerStyle(.menu)
            if !tags.isEmpty {
                Picker("Tag", selection: $tagFilter) {
                    Text("All Tags").tag(Tag?.none)
                    ForEach(tags) { tag in
                        Text(tag.name).tag(Tag?.some(tag))
                    }
                }
                .pickerStyle(.menu)
            }
            if hasAnyFilter {
                Divider()
                Button("Clear Filters", systemImage: "xmark.circle") { clearFilters() }
            }
        } label: {
            Label(
                "Filter",
                systemImage: categoryFilter != nil || accountFilter != nil
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
    }

    private var hasAnyFilter: Bool {
        quickFilter != .all || categoryFilter != nil || accountFilter != nil || tagFilter != nil || !searchText.isEmpty
    }

    private func clearFilters() {
        withAnimation(CairnTheme.Motion.quick) {
            quickFilter = .all
            categoryFilter = nil
            accountFilter = nil
            tagFilter = nil
            searchText = ""
        }
    }

    private var emptyMessage: String {
        if allTransactions.isEmpty {
            return "Sync a bank or import a CSV to see transactions here."
        }
        return "Try a different search or clear the filters."
    }

    // MARK: - Filtering

    private var filtered: [LedgerTransaction] {
        var result = allTransactions
        switch quickFilter {
        case .all: break
        case .spending: result = result.filter { $0.amountMinorUnits < 0 && !$0.countsAsTransfer }
        case .income: result = result.filter { $0.amountMinorUnits > 0 && !$0.countsAsTransfer }
        case .pending: result = result.filter(\.isPending)
        case .uncategorized: result = result.filter { $0.effectiveCategory == nil && !$0.countsAsTransfer && !$0.isIgnored }
        }
        if let categoryFilter {
            result = result.filter { $0.effectiveCategory?.persistentModelID == categoryFilter.persistentModelID }
        }
        if let accountFilter {
            result = result.filter { $0.account?.persistentModelID == accountFilter.persistentModelID }
        }
        if let tagFilter {
            result = result.filter { transaction in
                (transaction.tags ?? []).contains { $0.persistentModelID == tagFilter.persistentModelID }
            }
        }
        if !searchText.isEmpty {
            result = result.filter { transaction in
                transaction.payeeDescription.localizedStandardContains(searchText)
                    || (transaction.account?.displayName.localizedStandardContains(searchText) ?? false)
                    || (transaction.effectiveCategory?.name.localizedStandardContains(searchText) ?? false)
                    || (transaction.note?.localizedStandardContains(searchText) ?? false)
                    || (transaction.tags ?? []).contains {
                        $0.name.localizedStandardContains(searchText)
                    }
            }
        }
        // Pending transactions have no posted date, so sort by the effective
        // date to keep them at the top instead of the bottom.
        return result.sorted { $0.effectiveDate > $1.effectiveDate }
    }
}
