# Performance and scaling

Long ledgers are the app's worst scaling case: a person can accumulate tens of
thousands of transactions, and every list that shows them must stay smooth.
This note records how the transaction lists and Insights are structured, and
what is deliberately left for a follow-up.

## Transaction lists

`CairnApp/Features/Transactions/TransactionsFeed.swift` owns the window.

- It fetches one page at a time with `FetchDescriptor.fetchLimit` /
  `fetchOffset`, sorted by `postedDate`, so opening Activity never materializes
  the whole store.
- Each fetched model is mapped once to a `TransactionRowValue`, a `Sendable`
  snapshot (`Sources/CairnCore/Transactions/TransactionPresentation.swift`).
  The view diffs values, so one changed transaction cannot re-evaluate every
  row.
- The window starts at `ListWindow.initialLimit` (60) and grows by one page as
  the last row appears. New pages are appended at the bottom, so already-visible
  rows keep their positions and the viewport stays anchored.
- Pending rows have no `postedDate`, so they are fetched separately and kept at
  the top, matching the list's historic effective-date ordering.
- `TransactionList.swift` groups the snapshots into month/day sections once
  (`TransactionSectionBuilder`) and keys each element by the stable composite
  `accountIDIndex/bankTransactionID`. One view is emitted per element, divider
  included.
- Search is debounced with `.task(id:)` + `Task.sleep` (`SearchDebounce`).

## The predicate split, and why

A single `#Predicate` literal combining the pending partition, the quick filter,
the category/account/tag relationships, and multi-field search does not compile:
the Swift type-checker gives up on the expanded expression ("unable to
type-check this expression in reasonable time"). Combining separate `Predicate`
values is not available on the iOS 26 / macOS 26 baseline either; the
composition initializer `Predicate(all:)` is 27-or-newer, and the
`PredicateExpressions` route needs concrete expression types that an array of
`Predicate` values does not preserve.

So the query is split:

- **SQL (`TransactionFetch.predicate`).** The pending partition, the quick
  sign, and the account. These are single comparisons that compile reliably and
  cut the store down before any rows are loaded.
- **Snapshot refinement (`TransactionRefinement`).** The built-in
  money-movement exclusion, the exact category match, tag membership, and
  free-text search. `TransactionsFeed.fillPosted` scans pages in date order,
  applying refinement, and stops as soon as the window is full. For the default
  unfiltered view, no scanning happens beyond the first page.

This keeps filter semantics exact (the window applies to the filtered result)
and keeps the common case cheap, at the cost of scanning more pages when a rare
search term is used.

### Follow-up

Push the refinement filters into SQL so a rare search does not scan. The path is
to compose predicates once the deployment target allows `Predicate(all:)`, or to
build the conjunction with `PredicateExpressions.build_Conjunction` over
concrete expression types. The split is isolated in `TransactionFetch`, so the
change is local.

## Insights

`InsightsFetcher` (`Sources/CairnCore/Insights/InsightsFetcher.swift`) is a
`@ModelActor` that fetches transactions for the visible accounts, windows them
to `InsightsCalculator.earliestUsedDate`, and maps them to `Sendable`
`InsightTransaction` values. `InsightsView` awaits the result in
`.task(id:)` and computes the snapshot from those values on the main actor. The
actor is constructed inside a `Task.detached` because the generated initializer
binds its executor to the calling thread; constructing it on the main actor
would leave the work there.

## Deliberately unchanged

- `InsightsView` still reads `account.transactions` for `NetWorthMath.series`
  and the account-detail sparkline. Those relationship walks are the next
  scaling target.
- `InsightFilteredListView` still uses a `@Query` and filters in Swift; it maps
  the models to snapshots for drawing, but does not yet window.
