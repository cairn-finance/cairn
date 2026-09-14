import SwiftUI
import SwiftData
import CairnCore

struct CurrencyTotal: Identifiable {
    var id: String { currency.code }
    let currency: Currency
    let totalMinorUnits: Int64
}

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Institution.name) private var institutions: [Institution]
    @Query(
        filter: #Predicate<Account> { $0.isHidden == false },
        sort: [SortDescriptor(\Account.displayOrder)]
    )
    private var accounts: [Account]

    @State private var showingConnect = false
    @State private var showingManualAccount = false

    var body: some View {
        List {
            if !netWorthTotals.isEmpty {
                Section {
                    netWorthHeader
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            ForEach(institutions) { institution in
                let institutionAccounts = accounts.filter {
                    $0.institution?.persistentModelID == institution.persistentModelID
                }
                if !institutionAccounts.isEmpty {
                    Section {
                        ForEach(institutionAccounts) { account in
                            NavigationLink {
                                AccountDetailView(account: account)
                            } label: {
                                AccountRow(account: account)
                            }
                        }
                    } header: {
                        HStack {
                            Text(institution.name.isEmpty ? "Institution" : institution.name)
                            Spacer()
                            if let date = institution.lastSyncDate {
                                Text(date, format: .relative(presentation: .named))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Not synced yet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !manualAccounts.isEmpty {
                Section("Manual Accounts") {
                    ForEach(manualAccounts) { account in
                        NavigationLink {
                            AccountDetailView(account: account)
                        } label: {
                            AccountRow(account: account)
                        }
                    }
                }
            }
        }
        .cairnListStyle()
        .navigationTitle("Accounts")
        .toolbar { toolbarContent }
        .refreshable { await model.syncAll(force: true) }
        .overlay {
            if accounts.isEmpty {
                EmptyStateView(
                    systemImage: "building.columns",
                    title: "No accounts yet",
                    message: "Connect a bank through SimpleFIN to see balances and transactions here.",
                    actionTitle: "Connect a Bank"
                ) {
                    showingConnect = true
                }
            }
        }
        .sheet(isPresented: $showingConnect) {
            NavigationStack {
                ScrollView {
                    ConnectBankView { showingConnect = false }
                        .padding()
                }
                .navigationTitle("Add Institution")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingConnect = false }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 420)
            #endif
        }
        .sheet(isPresented: $showingManualAccount) {
            ManualAccountSheet()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.syncAll(force: true) }
            } label: {
                if model.syncState == .syncing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(model.syncState == .syncing)
        }
        ToolbarItem {
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
    }

    private var manualAccounts: [Account] {
        accounts.filter { $0.institution == nil }
    }

    private var netWorthTotals: [CurrencyTotal] {
        let included = accounts.filter(\.includeInNetWorth)
        let grouped = Dictionary(grouping: included) { $0.currency.code }
        return grouped.compactMap { _, group in
            guard let currency = group.first?.currency else { return nil }
            let total = group.reduce(Int64(0)) { $0 + $1.balanceMinorUnits }
            return CurrencyTotal(currency: currency, totalMinorUnits: total)
        }
        .sorted { $0.currency.code < $1.currency.code }
    }

    private var netWorthHeader: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Net Worth")

                if netWorthTotals.count == 1, let only = netWorthTotals.first {
                    AmountText(
                        money: Money(minorUnits: only.totalMinorUnits, currency: only.currency),
                        font: .system(.largeTitle, weight: .bold)
                    )
                } else {
                    ForEach(netWorthTotals) { total in
                        HStack {
                            Text(total.currency.displayLabel)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            AmountText(
                                money: Money(minorUnits: total.totalMinorUnits, currency: total.currency),
                                font: .title3.weight(.semibold)
                            )
                        }
                    }
                    if netWorthTotals.count > 1 {
                        Text("Currencies are shown separately until exchange rates are supported.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
