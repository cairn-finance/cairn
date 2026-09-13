import SwiftUI
import SwiftData
import CairnCore

struct AccountDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let account: Account
    @Query private var transactions: [LedgerTransaction]

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
    private var sortedTransactions: [LedgerTransaction] {
        transactions.sorted { $0.effectiveDate > $1.effectiveDate }
    }

    var body: some View {
        List {
            Section {
                summary
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if transactions.isEmpty {
                Section {
                    Text("No transactions yet. Sync to fetch recent activity.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } else {
                Section("Transactions") {
                    ForEach(sortedTransactions) { transaction in
                        NavigationLink {
                            TransactionDetailView(transaction: transaction)
                        } label: {
                            TransactionRow(transaction: transaction)
                        }
                    }
                }
            }
        }
        .cairnListStyle()
        .navigationTitle(account.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Include in Net Worth", isOn: Binding(
                        get: { account.includeInNetWorth },
                        set: { account.includeInNetWorth = $0; try? modelContext.save() }
                    ))
                    Toggle("Hide Account", isOn: Binding(
                        get: { account.isHidden },
                        set: { account.isHidden = $0; try? modelContext.save() }
                    ))
                } label: {
                    Label("Account Options", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var summary: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(account.institution?.name ?? "Account")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                AmountText(
                    money: account.balance,
                    font: .system(.largeTitle, design: .rounded, weight: .bold)
                )

                if account.hasAvailableBalance, account.availableBalance.minorUnits != account.balance.minorUnits {
                    HStack(spacing: 6) {
                        Text("Available")
                            .foregroundStyle(.secondary)
                        AmountText(money: account.availableBalance, font: .callout.weight(.medium))
                    }
                }

                if let date = account.balanceDate {
                    Text("Balance as of \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct TransactionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CairnSchemaV1.Category.sortOrder) private var categories: [CairnSchemaV1.Category]

    let transaction: LedgerTransaction

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(transaction.payeeDescription)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    AmountText(
                        money: transaction.amount,
                        showSign: true,
                        font: .system(.largeTitle, design: .rounded, weight: .bold)
                    )
                    if transaction.isPending {
                        Label("Pending", systemImage: "clock")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Categorize") {
                Picker("Category", selection: categoryBinding) {
                    Text("Uncategorized").tag(UUID?.none)
                    ForEach(categories.filter { !$0.isArchived }) { category in
                        Label(category.name, systemImage: category.symbolName)
                            .tag(UUID?.some(category.uuid))
                    }
                }
                if transaction.isCategorizedByUser {
                    Text("Manually set. Automatic rules and on-device suggestions will not override it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Options") {
                Toggle("Transfer", isOn: Binding(
                    get: { transaction.isTransfer },
                    set: { transaction.isTransfer = $0; touch() }
                ))
                Toggle("Ignore", isOn: Binding(
                    get: { transaction.isIgnored },
                    set: { transaction.isIgnored = $0; touch() }
                ))
            }

            Section("Details") {
                LabeledContent("Date") {
                    Text(transaction.effectiveDate, format: .dateTime.year().month().day())
                }
                LabeledContent("Account") {
                    Text(transaction.account?.displayName ?? "—")
                }
                LabeledContent("Institution") {
                    Text(transaction.account?.institution?.name ?? "—")
                }
                LabeledContent("Transaction ID") {
                    Text(transaction.bankTransactionID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Note") {
                TextField("Add a note", text: noteBinding, axis: .vertical)
                    .lineLimit(2...6)
            }
        }
        .navigationTitle("Transaction")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var categoryBinding: Binding<UUID?> {
        Binding(
            get: { transaction.userCategory?.uuid },
            set: { newValue in
                if let newValue {
                    transaction.userCategory = categories.first { $0.uuid == newValue }
                } else {
                    transaction.userCategory = nil
                }
                touch()
            }
        )
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
