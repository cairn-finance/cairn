import Foundation
import Observation
import SwiftData
import CairnCore

/// Owns the bounded window of transactions a list shows.
///
/// SwiftUI used to drive every transaction list with a `@Query` that loaded the
/// whole store on the main actor and filtered it in Swift inside `body`. This
/// feed instead fetches one page at a time with `fetchLimit`/`fetchOffset`,
/// snapshots each row to a `Sendable` value, and grows the window as the reader
/// nears the end. The view only ever diffs the window.
///
/// The predicate carries the cheap SQL filters (pending, sign, account); the
/// remaining filters run over the snapshots as pages arrive. Scanning stops as
/// soon as the window is full, so a rare filter costs more only when one is
/// actually applied.
@MainActor
@Observable
final class TransactionsFeed {
    private let container: ModelContainer

    private(set) var rows: [TransactionRowValue] = []
    private(set) var sections: [TransactionMonthSection] = []
    /// True when the store has no transactions at all, so the empty state can
    /// say "No activity yet" rather than "Nothing matches".
    private(set) var isStoreEmpty = false
    private(set) var hasMore = false
    /// The SQL-level count for the account/quick filter, without the snapshot
    /// refinement. Used where a total is shown rather than a window.
    private(set) var sqlCount = 0

    var filter: TransactionFilter {
        didSet {
            if filter != oldValue { reload() }
        }
    }

    private var window = ListWindow()
    private var posted: [TransactionRowValue] = []
    private var pending: [TransactionRowValue] = []
    private var scanOffset = 0
    private var scanExhausted = false
    private var changeTask: Task<Void, Never>?

    init(container: ModelContainer, filter: TransactionFilter = TransactionFilter()) {
        self.container = container
        self.filter = filter
        reload()
        observeStoreChanges()
    }

    /// Rebuilds the window from the start. Called on filter changes and when the
    /// store changes.
    func reload() {
        window.reset()
        scanOffset = 0
        scanExhausted = false
        posted = []
        pending = []
        isStoreEmpty = (try? container.mainContext.fetchCount(FetchDescriptor<LedgerTransaction>())) == 0
        sqlCount = (try? container.mainContext.fetchCount(TransactionFetch.countDescriptor(filter: filter))) ?? 0
        pending = fetchPending()
        fillPosted(upTo: window.limit)
        rebuildRows()
    }

    /// Loads one more page. Called when the last visible row appears.
    func loadMore() {
        guard hasMore else { return }
        window.advance()
        fillPosted(upTo: window.limit)
        rebuildRows()
    }

    private func rebuildRows() {
        rows = (pending + posted).sorted { $0.effectiveDate > $1.effectiveDate }
        sections = TransactionSectionBuilder.months(from: rows)
        hasMore = !scanExhausted
    }

    /// Pending rows have no posted date, so a posted-date window would push them
    /// off the end. They are few, so they are fetched whole and kept at the top,
    /// matching how the list always sorted by effective date.
    private func fetchPending() -> [TransactionRowValue] {
        let descriptor = TransactionFetch.descriptor(filter: filter, pending: true)
        let models = (try? container.mainContext.fetch(descriptor)) ?? []
        return models
            .map { $0.rowValue() }
            .filter { TransactionRefinement.matches($0, filter: filter) }
    }

    /// Scans posted rows in date order, refining until the window is full or the
    /// store runs out.
    private func fillPosted(upTo target: Int) {
        while posted.count < target && !scanExhausted {
            let descriptor = TransactionFetch.descriptor(
                filter: filter,
                pending: false,
                limit: ListWindow.pageSize,
                offset: scanOffset
            )
            let page = (try? container.mainContext.fetch(descriptor)) ?? []
            if page.count < ListWindow.pageSize { scanExhausted = true }
            scanOffset += page.count
            for model in page {
                let value = model.rowValue()
                if TransactionRefinement.matches(value, filter: filter) {
                    posted.append(value)
                }
            }
            if page.isEmpty { scanExhausted = true }
        }
    }

    /// Reloads when any context saves or iCloud delivers a change, so a newly
    /// categorized or synced transaction appears without reopening the screen.
    private func observeStoreChanges() {
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            let changes = NotificationCenter.default.notifications(named: ModelContext.didSave)
            for await _ in changes {
                guard let self else { return }
                if Task.isCancelled { return }
                self.reload()
            }
        }
    }
}
