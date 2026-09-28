import SwiftUI
import SwiftData
import CairnCore

/// A deliberately conservative view of connection freshness. It describes the
/// last data Cairn received; it does not suggest that balances are live.
struct ConnectionHealthView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Institution.name) private var institutions: [Institution]

    @State private var showingConnect = false
    @State private var showingManualAccount = false

    private var visibleInstitutions: [Institution] {
        Institution.listedAsBanks(institutions)
    }

    var body: some View {
        List {
            Section {
                Label("Connection Health", systemImage: "heart.text.square.fill")
                    .font(.headline)
                Text("Cairn shows when each source last succeeded and the oldest data currently stored. This is cached information, not a live bank balance.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if visibleInstitutions.isEmpty {
                Section {
                    Text("No bank connections yet. Add a connection, or use a manual account and import a CSV for a source SimpleFIN cannot reach.")
                        .foregroundStyle(.secondary)
                    Button("Add a Connection", systemImage: "plus") { showingConnect = true }
                    Button("Create a Manual Account", systemImage: "pencil.and.list.clipboard") {
                        showingManualAccount = true
                    }
                }
            } else {
                Section("Sources") {
                    ForEach(visibleInstitutions) { institution in
                        healthCard(for: institution)
                    }
                }
            }

            Section("If a source needs attention") {
                Label("Retry when you are online. If the saved connection no longer works, add it again with a new SimpleFIN setup token.", systemImage: "arrow.clockwise")
                Label("For a bank or account SimpleFIN cannot reach, create a manual account and import its CSV. Cairn never moves money.", systemImage: "doc.text.arrow.up")
            }
        }
        .cairnListStyle()
        .navigationTitle("Connection Health")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showingConnect) {
            AddConnectionSheet { showingConnect = false }
                .cairnLockCover()
        }
        .sheet(isPresented: $showingManualAccount) {
            ManualAccountSheet()
                .cairnLockCover()
        }
        .refreshable { await model.syncAll(force: true) }
    }

    private func healthCard(for institution: Institution) -> some View {
        let snapshot = snapshot(for: institution)
        let status = ConnectionHealthEvaluator.status(for: snapshot, now: .now)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon(for: status))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(color(for: status))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(institution.name.isEmpty ? "Institution" : institution.name)
                        .font(.headline)
                    Text("SimpleFIN · \(statusTitle(status))")
                        .font(.subheadline)
                        .foregroundStyle(color(for: status))
                }
                Spacer()
            }

            detailRows(for: institution, snapshot: snapshot)

            if let error = snapshot.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(CairnTheme.negative)
                    .lineLimit(3)
            }

            Text(guidance(for: status))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if status == .failed || status == .stale || status == .offline {
                    Button("Retry Sync", systemImage: "arrow.clockwise") {
                        Task { await model.syncAll(force: true) }
                    }
                    .disabled(model.syncState == .syncing || status == .offline)
                }
                if status == .failed || status == .reconnect {
                    Button("Reconnect", systemImage: "link.badge.plus") { showingConnect = true }
                }
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func detailRows(for institution: Institution, snapshot: ConnectionHealthSnapshot) -> some View {
        LabeledContent("Last successful sync") {
            if let date = snapshot.lastSuccessfulSync {
                Text(date, format: .relative(presentation: .named))
            } else {
                Text("Never")
            }
        }
        LabeledContent("Latest transaction") {
            if let date = snapshot.lastTransactionDate {
                Text(date, format: .dateTime.year().month().day())
            } else {
                Text("Not available")
            }
        }
        LabeledContent("Requests remaining today") {
            Text("\(snapshot.requestsRemaining) of \(SyncEngine.dailyRequestLimit)")
                .monospacedDigit()
        }
        if snapshot.hasPendingTransactions {
            Label("Pending transactions are still awaiting a posted result.", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(CairnTheme.warning)
        }
    }

    private func snapshot(for institution: Institution) -> ConnectionHealthSnapshot {
        let now = Date.now
        let requestsRemaining: Int
        if let date = institution.dailyRequestDate,
           Calendar.current.isDate(date, inSameDayAs: now) {
            requestsRemaining = max(0, SyncEngine.dailyRequestLimit - institution.dailyRequestCount)
        } else {
            requestsRemaining = SyncEngine.dailyRequestLimit
        }
        let transactions = (institution.accounts ?? []).flatMap { $0.transactions ?? [] }
        return ConnectionHealthSnapshot(
            lastSuccessfulSync: institution.lastSuccessfulFetch,
            lastTransactionDate: transactions.compactMap { $0.postedDate ?? $0.transactedAt }.max(),
            requestsRemaining: requestsRemaining,
            hasPendingTransactions: transactions.contains(where: \.isPending),
            errorMessage: institution.lastSyncError,
            hasCredential: model.hasCredential(for: institution),
            isOffline: model.isOffline,
            isSyncing: model.syncState == .syncing
        )
    }

    private func statusTitle(_ status: ConnectionHealthStatus) -> String {
        switch status {
        case .healthy: "Healthy"
        case .stale: "Stale"
        case .failed: "Sync failed"
        case .limited: "Request limit reached"
        case .pending: "Syncing"
        case .offline: "Offline"
        case .reconnect: "Reconnect needed"
        }
    }

    private func guidance(for status: ConnectionHealthStatus) -> String {
        switch status {
        case .healthy: "Last sync completed successfully. Stored balances and transactions remain as-of that sync."
        case .stale: "No successful sync in the last day and a half. Retry to refresh; stored data may be out of date."
        case .failed: "The last attempt failed. Retry, or reconnect this source if its authorization has changed."
        case .limited: "SimpleFIN has no requests left for this connection today. It can try again tomorrow."
        case .pending: "A sync is in progress. Until it completes, the information shown here is from the previous successful sync."
        case .offline: "Sync is paused while offline. Stored data remains available and will refresh when the connection returns."
        case .reconnect: "This device cannot read the saved connection. Reconnect it, or connect again with a new setup token."
        }
    }

    private func icon(for status: ConnectionHealthStatus) -> String {
        switch status {
        case .healthy: "checkmark.circle.fill"
        case .stale: "clock.badge.exclamationmark"
        case .failed: "exclamationmark.triangle.fill"
        case .limited: "gauge.with.dots.needle.67percent"
        case .pending: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        case .reconnect: "link.badge.plus"
        }
    }

    private func color(for status: ConnectionHealthStatus) -> Color {
        switch status {
        case .healthy: CairnTheme.positive
        case .pending, .stale, .limited, .offline: CairnTheme.warning
        case .failed, .reconnect: CairnTheme.negative
        }
    }
}
