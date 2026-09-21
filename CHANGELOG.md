# Changelog

All notable changes to Cairn are documented here. This project follows
[Semantic Versioning](https://semver.org) and
[Keep a Changelog](https://keepachangelog.com).

## [1.0.0] - 2026-09-21

- docs: note public support pages
- docs: publish support and privacy pages
- Catalog the chart descriptor strings
- Add VoiceOver chart details and a Mac action menu
- Honor Reduce Motion in the remaining animations
- Hide decorative icons from VoiceOver
- Let VoiceOver step through the charts
- Scale the remaining fixed fonts and label chart values
- Make headline figures and charts accessible
- Label controls, charts, and state for VoiceOver
- Check in the extracted String Catalog
- Add a Sync Cairn App Intent and pin chart label anchors
- Clear every Swift compiler and SwiftLint warning
- Keep merged localization strings within the lint limit
- Note windowed lists and off-main Insights in the changelog
- Avoid empty-state flashes while windowed lists load
- Build Insights input on a background model actor
- Feed transaction lists from a bounded window
- Add windowed transaction snapshots and list-window policy
- Add localization scaffolding and plural-aware UI strings
- Replace force tries in the banner script
- Fix manual-entry and category data integrity
- Resume sync automatically when the network returns
- Add category management to Settings
- Show clear empty, offline, and sync-failure states
- Add manual-account transaction editing
- Log backfill rows dropped for accounts the store lost
- Accept a range warning that arrives with rows
- Backfill older transaction history on connect and first sync
- Note the duplicate-connection repair in the changelog
- Fix a crash when a repair invalidates rows the UI still maps
- Add a Debug-only flag to preview credential re-keying
- Describe the duplicate banner in visible terms
- Skip a connection the repair merged away mid-sync
- Match a stored connection that has no organization id
- Keep the working Access URL when re-keying a merged credential
- Import to a duplicate connection's survivor during sync
- Test connection matching, repair, removal, and re-keying
- Wire claim matching and the duplicate repair into the app
- Match SimpleFIN connections by identity across credentials
- Rewrite the changelog for users
- Add CI and release workflows
- Point the README at the public TestFlight beta
- Use the maintainer email for security reports
- Say the TestFlight beta is coming, not live
- Match the architecture doc's encryption notes to the schema
- Hide the TestFlight placeholder until the link exists
- Say which fields CloudKit encrypts and which stay plaintext
- Fit the README screenshots on a phone screen
- Point About at the public privacy and support pages
- Date the privacy policy and clarify Wallet and iCloud
- State the trademark carve-out in NOTICE
- Point security reports at a placeholder contact
- Add issue and pull request templates
- Rewrite the README as a landing page
- Add landing-page screenshots
- Add a banner generator and its output
- Set the sample institution's last successful sync
- Set syncing only once a reconnect will proceed
- Record that iPad Wallet removal is not authoritative
- Categorize the sample ledger in sample mode
- Wait for the import before offering a reconnect
- Finish onboarding after reconnecting on it
- Guard a reconnect against double taps
- Give new source files a trailing newline
- Reconnect an orphaned SimpleFIN credential
- Never replace a failed store with an empty one
- Show the sample account as healthy and trending up
- Wrap long lines and drop an unused test binding
- Isolate battery reads to the main actor
- Surface export failures through the banner
- Keep Wallet removal off the Mac, where it can't stick
- Let the sandboxed Mac app open the picked file
- Raise the regex deadline to two seconds and test it via budget
- Work from merchants and a window, not the whole ledger
- Record why a Wallet disconnect cannot stick
- Bound a regex rule's work
- Record the CloudKit promotion
- Make the schema initializer print CloudKit rule violations
- Keep the encrypted date out of the index
- Give the initializer a runnable example
- Warn that the container setting repoints every build
- Say what a bad container actually does
- Hash the schema declarations rather than the file text
- Declare the whole schema in one pass
- Encrypt dates, the account type, and balance days
- Point the contributor docs at the container setting
- Add a schema hash check and the CloudKit promotions record
- Resolve the CloudKit container from one setting
- Encrypt every field that reveals financial detail
- Do not prompt while the screen is away
- Judge each Keychain copy on its own
- Ask the store for the last two cached lookups
- Clamp the projected-spend conversion
- Serve cached currencies after the lookup cap
- Stop treating a card shop as a card issuer
- Re-engage the Mac lock when the screen locks
- Rewrite a credential only when it differs
- Ask the store before writing to an institution
- Complete a background task through one gate
- Cover the card-payment path through the bank name
- Ask about storage before the connect buttons
- Clear Wallet bookkeeping on Delete All Data
- Preserve the screen across a lock
- Fix Keychain copies and bound custom-currency lookups
- Keep card payments out of spending
- Make the post-await crash guard store-backed
- Clamp the remaining money sums
- Match counterparty names on word boundaries
- Ignore local screenshot captures
- Align the docs, Info.plist, and background task with the app
- Fix the changelog, the release script, and custom currencies
- Default iCloud sync to off and ask during onboarding
- Harden the diagnostics log, Keychain, lock, regex, and money math
- Clear holdings, logs, and preferences in Delete All Data
- Restrict Wallet account removal to accounts this device has seen
- Re-resolve rows after model calls during categorization
- Stop treating bill payments as transfers
- Match institution names on word boundaries

## [Unreleased]

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
