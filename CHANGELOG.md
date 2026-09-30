# Changelog

All notable changes to Cairn are documented here. This project follows
[Semantic Versioning](https://semver.org) and
[Keep a Changelog](https://keepachangelog.com).

## [Unreleased]

### Added

- Home Screen widgets show net worth and month-to-date spending, with amounts
  kept separate by currency and refreshed from saved data.
- Transaction details link to merchant pages with the merchant's transactions
  and week, month, and year spending totals.
- Cash-flow forecast details show each currency’s lowest projected balance and
  30-day outlook, with links to confirmed plans and connection health.
- Home Screen and Lock Screen forecast widgets use layouts suited to each size,
  with sample gallery previews and freshness information.
- Alerts have individual controls for connection health, forecast shortfalls,
  and confirmed plans, plus a test alert in Settings.

### Fixed

- Security purchases and sales in investment accounts are treated as money
  movement instead of shopping or income. Earlier automatic shopping labels
  are corrected without changing manual categories or transaction amounts.
- Small forecast widgets use a compact layout, and sync labels show a fixed
  time or date instead of a ticking elapsed-time counter.
- Notification responses complete on the main thread to avoid a UIKit
  assertion while handling alerts.
- Widgets adopt the system container background so gallery previews render
  correctly.
- Notification taps and widget links open the relevant forecast, connection
  health, or confirmed plan, including alerts delivered by earlier versions.
- Confirmed plans can send due-date reminders before their first observed
  payment. Unresolved alerts no longer repeat after delivery or dismissal.
- Stale-connection alerts are scheduled ahead of time and upcoming plans remind
  a day before they are due.

## [1.3.0] - 2026-09-29

### Added

- Spread a one-time expense across monthly budgets with a custom name and
  schedule while keeping the original transaction amount in history and
  account balances.

## [1.2.1] - 2026-09-29

### Fixed

- Recurring payment details use detached commitment snapshots while the store
  reconciles background updates.

## [1.2.0] - 2026-09-28

### Changed

- Insights category progress bars now use the same total-spending percentage as
  the category chart.

- Budget category drill-downs now use the same bounded, read-only transaction
  feed as Activity instead of materializing the full ledger on navigation.

- Budgeting can be turned off in Settings to hide budget cards, Insights links,
  and budget exports without deleting saved limits.

- Forecasts, budgets, net worth, insights, and recurring views now keep full
  currency descriptors separate instead of grouping by currency code alone.

- Confirmed commitments reconcile observed payments without overwriting user
  edits, and duplicate synced plans preserve the newest user-owned revision.

- Shared-expense links now survive safe duplicate-account repair, can be
  unlinked, and offset the linked expense in Insights and budgets without
  turning the reimbursement into income or a transfer.

- Widgets and local alerts now expire stale snapshots, remove Cairn-owned
  notifications when data is locked or deleted, and report due-today and
  changed commitments without exposing financial detail.

- Shortcuts now report unavailable stores, locked data, missing connections,
  and sync failures instead of returning an empty or successful result.

- Budget and commitment editing validates amounts, review actions explain why
  uncategorized rows remain, and new system-surface, settlement, currency,
  localization, and accessibility strings are covered.

- Existing stores now migrate from schema V3 to schema V4 before using
  settlement metadata and confirmed commitments, preserving data from earlier
  installs.

- Fixed physical-device installation for the widget extension by declaring its
  executable in the extension bundle metadata.

- Confirmed commitments can now be exported as CSV alongside transactions and
  budgets, and the generated macOS app no longer builds or embeds the iOS-only
  widget extension.

- Added a redacted forecast-status widget, intentional local alerts for stale or
  actionable financial states, and read-only Shortcuts actions for review and
  forecast status. System surfaces show aggregate status and freshness only;
  they do not expose merchant detail, credentials, or live bank data.

- Recurring detections can become user-owned bill or income commitments, with a
  per-currency cash-flow forecast that labels stale sources and uncertainty.
  Forecasts are estimates, not real-time bank balances or guarantees.

- Shared expenses can link one outgoing bank row to one incoming reimbursement
  while preserving both original rows and showing gross, received, net, and
  outstanding amounts.
- Added a Review Inbox in Activity for uncategorized, unreviewed, and changed
  transactions, with explanations, category editing, review actions, and undo.
- Settings now includes a Connection Health center showing each source's last
  successful sync, transaction coverage, request-limit state, and stale or failed
  status with retry, reconnect, and manual-account guidance.
- Insights now subtracts categorized reimbursements, such as roommate rent
  payments, from the expense category they belong to.
- Home and Insights use adaptive dashboard layouts on iPad and Mac, navigation
  adapts between tabs and sidebars, and key filters and actions use the current
  Apple control appearance. Home also shows this month's planned category
  budget, and Insights opens the budget for the selected month and currency.
- Insights controls keep inactive month choices legible in dark mode, and the
  category chart now supports single-tap selection with category-level detail.
  The category list expands to its content without an inner scroll view.

## [1.1.0] - 2026-09-27

### Added

- Rules can set a displayed transaction name, apply tags, and make matching
  transaction rows compact. Regex rules can use capture groups in names.
- Transaction details show every matching rule and open its editor.
- A Settings option makes all transaction rows compact.
- Browse spending with a category chart, then swipe to category amounts and
  open lists of transactions matching a tag or rule in Insights.
- Choose which sections appear in the tab bar or sidebar and change their order
  from Settings.
- Monthly category budgets with recurring limits, one-month overrides, and
  CSV export. Starting suggestions show each month's spending and let you
  review the combined plan before adding limits.
- Reset all budget limits without deleting accounts or transactions.

### Changed

- Multiple matching rules now combine their actions. Higher rules win when
  they set different names or categories on the same transaction.
- Limit editing now shows the month scope explicitly and keeps the current
  scope selected when editing an existing limit.
- Starting suggestions require spending in two completed months. Budget cards
  and the suggestion sheet use shorter labels and clearer amount fields on iPhone.

### Fixed

- Settings no longer displays a localization resource’s debug description in
  the Storage footer.
- Opening a recurring payment now loads its charges without crashing when
  synced transactions change in the background.
- Budget remaining now compares planned limits with spending in those planned
  categories. Other spending is shown separately.
- A failed transaction load no longer appears as zero budget spending.
- Empty budget suggestion states no longer prompt for a new account.

## [1.0.0] - 2026-09-21

### Added

- Public GitHub Pages for privacy and support, with in-app and community links
  pointing to the Cairn organization.
- A public README, issue and pull request templates, a security policy, and
  refreshed privacy and support pages.
- CI checks (tests and the schema hash) and a tag-driven release process that
  builds and uploads to TestFlight.
- Older transaction history is backfilled in 45-day pages, so a connection shows
  as much history as the institution exposes, not just the most recent window.
- Manual accounts can now be edited in the app: add, edit, and delete single
  transactions, and rename or delete the account itself.
- Categories can be added, renamed, recolored, reordered, and archived, and a
  category that nothing uses can be deleted.
- An offline indicator on Home and Settings explains that sync is paused and
  cached data still works, and onboarding offers a clear path to create a manual
  account or import a CSV without connecting a bank.
- Empty states with a short explanation and a next step on Home, Activity,
  Insights, Investments, Recurring, Rules, Tags, and account detail.
- A "Sync Cairn" action for Siri, Shortcuts, and Spotlight.
- A String Catalog with Info.plist usage descriptions, so every user-facing
  string is extractable and ready to translate.
- Accessibility: labeled controls, buttons, and charts; headline figures scale
  with Dynamic Type; Reduce Motion and Reduce Transparency are honored; chips,
  swatches, and segmented controls report their selected state; charts offer
  VoiceOver chart details and an audio graph; and destructive connection actions
  are reachable by keyboard on the Mac.

### Changed

- Shared components, core display labels, and sync banners now take
  localization-ready string types instead of plain `String`.
- Counts (transactions, rules, tags, accounts, and similar) use plural-aware
  strings instead of hand-built singular/plural suffixes.
- Amount entry parses the device locale's decimal separator, and percentage
  trends format with `FormatStyle`, so comma-decimal locales behave correctly.

- A sync that fails now stays visible as an actionable card with retry and
  diagnostics, and reads as "paused" rather than a failure while offline.
- Sync now uses a new CloudKit container, so data synced by earlier builds
  won't show up through it.
- Cloud sync now defaults to off on new installs; onboarding asks before
  anything is stored in iCloud.
- Removing Wallet data is offered on iPhone and iPad only.
- Documentation, Info.plist, and the background task now match the app.
- Activity and account history load a bounded window of rows and extend it as
  you scroll, instead of loading the whole ledger up front. Insights builds its
  figures off the main thread.

### Fixed

- A saved SimpleFIN connection can be reconnected after a reinstall.
- A bank saved twice as separate SimpleFIN connections is merged into one, so
  new transactions keep importing to the surviving connection and the working
  Access URL is kept.
- A store that fails to open shows an error instead of an empty app.
- CSV import and export work in the sandboxed Mac app.
- Export failures are reported instead of failing silently.
- Institution and counterparty names match on word boundaries, so purchases
  are no longer misread as transfers.
- Bill payments (autopay, bill pay, e-payment) count as card payments only
  when a card is named, and no longer disappear from spending.
- Card payments stay out of spending.
- Wallet sync removes only accounts this device has seen, and a transient
  empty result never deletes anything.
- Delete All Data removes holdings, the diagnostics log, recurring series,
  and the app-lock preference, and reports store failures.
- Categorization re-resolves rows after model calls, so a sync or delete
  cannot trap on a removed row.
- Keychain copies are judged individually, and switching sync modes no longer
  leaves a stale device-only credential behind.
- The lock covers presented sheets and the app switcher, and re-engages on
  macOS when the screen locks.
- Regex rules run under a deadline, custom-currency lookups are cached and
  capped, and money sums clamp instead of trapping.
- Sync paused by a lost connection resumes on its own when the network returns,
  and the offline explanation keeps the original error alongside it.
- A picked CSV is read off the main thread, so importing a large export no
  longer stalls the interface.

### Security

- CloudKit now encrypts every field that reveals financial detail, including
  merchant names, rule amount bounds, institution org fields, sync errors,
  currency codes, and custom-currency names.
- The setup token no longer reaches the diagnostics log, and device-only
  credentials use ThisDeviceOnly.

## [0.3.0] - 2026-09-16

### Added

- Recurring payments: subscriptions and regular charges are detected
  on-device and listed on a Recurring screen.
- Rules and tags: create, edit, reorder, enable, and delete rules with a live
  match preview, start a rule from a transaction, and assign tags with a tag
  filter.
- Card and loan payment categories, and on-device classification that knows
  whether money is in or out, so credits no longer land in spending
  categories.

### Changed

- Categorization asks the on-device model once per merchant, remembers its
  decisions, and pauses on thermal pressure or Low Power Mode; larger
  backlogs finish through a background task.

### Fixed

- Uncategorized rows are retried instead of being stranded, and stale model
  labels are overwritten once.
- Both legs of a transfer are matched across accounts.
- Deterministic hints outrank a fuzzy merchant match, so payroll income is no
  longer pulled into a spending category.
- Brokerage buys, sells, and reinvestments count as money movement, not
  spending.

## [0.2.0] - 2026-09-15

### Added

- Apple Wallet as a second data source: Apple Card, Apple Cash, and Savings
  connect through FinanceKit on iPhone and iPad.
- An app lock that requires Face ID, Touch ID, or the device passcode on
  launch and when the app leaves the foreground.

### Changed

- New SimpleFIN connections are named from their Access URL instead of
  "Connecting…".

### Fixed

- A missing credential is an actionable notice instead of a sync failure.
- Charts scrub to a vertical rule with the date and value, and sync status
  reflects what actually happened.
- On-device categorization backs off when the model is throttled instead of
  hammering it.
- Fees require a debit and an explicit charge word; payroll credits and
  transfers are classified correctly.

## [0.1.0] - 2026-09-15

### Added

- Exact money in integer minor units.
- A CloudKit-compatible SwiftData schema with encrypted fields.
- SimpleFIN credentials in the Keychain with optional iCloud sync, a claim
  and account-fetch client, and a sync engine with per-bank budget,
  pending-to-posted matching, balance history, rules, and CSV/JSON export.
- A SwiftUI app with onboarding, accounts, transactions, net worth, settings,
  and a shared design system.
- CSV import with Apple Card and Savings presets, and manual accounts.
- Insights: month-over-month income, spending, and category breakdowns.
- On-device merchant-memory categorization with optional Apple Intelligence.
- An Investments screen with last-synced positions, pushed from a Home
  summary card, and one institution per SimpleFIN connection.
- The Peak app icon.

### Fixed

- Month-end projections run from the current pace instead of the trailing
  average.
