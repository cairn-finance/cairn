# Architecture

Cairn is a single multiplatform SwiftUI app plus one local Swift package,
`CairnCore`, which contains every piece of logic that can be tested without a
simulator.

```
CairnApp (SwiftUI, iOS/iPadOS/macOS)
   │  @Query / @Observable
   ▼
CairnCore (Swift package)
   ├─ Models/        SwiftData @Model types (CairnSchemaV1)
   ├─ Persistence/   ModelContainerFactory, StoreMode
   ├─ Security/      CredentialStore, KeychainCredentialStore
   ├─ SimpleFIN/     client, DTOs, errors, sanitizer
   ├─ Sync/          SyncEngine (@ModelActor), matching, balance history
   ├─ Enrichment/    rules engine, merchant memory, transfer pairing
   ├─ Insights/      month-over-month math, subscription detection
   └─ Export/        CSV + JSON
```

Recurring detection (`RecurringDetector`) is pure and on-device: it groups
transactions by merchant and account, then keeps only runs of at least three
charges whose gaps fit a cadence (weekly through yearly) and whose amounts are
either fixed or vary like a bill. Transfers, ignored, and pending rows are left
out, and hidden accounts are skipped, so the list reflects only real
commitments. The app recomputes it after sync, import, categorization, and any
flag change.

## Data flow

1. **Onboarding** claims a SimpleFIN setup token. The client Base64-decodes it,
   requires HTTPS, `POST`s to the claim URL, and receives the Access URL.
2. The Access URL is stored in the **Keychain** keyed by a `credentialID` UUID;
   only that UUID and the institution metadata reach SwiftData.
3. **SyncEngine** (a `@ModelActor`) fetches `/accounts`, upserts institutions,
   accounts, and transactions off the main thread, reconciles pending→posted,
   applies rules, and records a balance snapshot.
4. SwiftUI reads through `@Query`. CloudKit propagates changes between devices.

## Signing and the iCloud container

Signing settings live in `Config/Signing.xcconfig` (committed defaults) plus an
optional, git-ignored `Config/Signing.local.xcconfig` for each developer's team
and bundle identifier. One build setting, `ICLOUD_CONTAINER_ID`, defines the
iCloud container: it feeds the entitlement's
`com.apple.developer.icloud-container-identifiers` and the `CairnCloudKitContainerID`
entry in `Info.plist`, which `ModelContainerFactory` reads at runtime. The
container the app requests and the container it is entitled to therefore cannot
disagree. It defaults to `iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)`, so each developer
gets their own container instead of a shared one; override it (locally, or from
the `ICLOUD_CONTAINER_ID` secret in CI) when the container is not derived from the
bundle id. Register that container (and enable CloudKit on the App ID) before
using Release builds that sync through iCloud.

Every configuration ships the **same** iCloud entitlement, so CloudKit works in
Debug and Release. Availability is decided at runtime in `CloudAvailability`:
the store uses CloudKit whenever `FileManager.default.ubiquityIdentityToken` is
non-nil (an iCloud account is available), and falls back to local-only otherwise.
This is required because asking CloudKit for a container without either the
entitlement or a registered container **traps** the process instead of throwing,
so the decision must be made before the store is created. `-cairn-disable-cloudkit`
forces local-only storage at runtime, and the test host always uses local storage.

## Why the schema looks the way it does

- **CloudKit constraints**: no `@Attribute(.unique)`, every scalar has a default,
  relationships are optional with explicit inverses.
- **Encrypted fields**: anything that reveals financial detail uses
  `@Attribute(.allowsCloudEncryption)` — amounts, descriptions, notes, dates,
  account and category names, `normalizedMerchant` (a plaintext copy would give
  away what encrypting `payeeDescription` protects), and identifying metadata
  such as the institution's org URL, the account type, and the account's
  custom-currency names. What stays plaintext is sync bookkeeping, flags, and
  opaque identifiers, which reveal little on their own: `modifiedAt`,
  `modifiedByDeviceID`, `isPending`, `isTransfer`, `isIgnored`,
  `hasAvailableBalance`, `displayOrder`, `credentialID`, `bankTransactionID`,
  `bankAccountID`, `bankConnectionID`, and `accountIDIndex`.
  Encryption status is irreversible once a schema reaches Production, which is
  why a new field's encryption attribute is treated as part of its type — see
  [`docs/releasing.md`](releasing.md#cloudkit-schema-promotions) and
  `Scripts/schema-hash.sh`.
- **Provenance**: transaction fields are split into bank-owned, automation-owned
  (`autoCategory`, `autoCategorySource`), and user-owned (`userCategory`, `note`,
  `tags`, `isTransfer`, `isIgnored`). No field has two writers, so CloudKit's
  field-level last-writer-wins cannot clobber a manual choice.
- **Money as integer minor units**: exact arithmetic, CloudKit-safe, and
  custom currencies (miles, points) work through a configurable exponent.
- **Derived history**: `balance(on: d) = currentBalance − Σ(amounts posted after d)`
  means the net-worth chart is populated from the first sync; snapshots are a
  cache.

## Sync behavior

- Each institution — one SimpleFIN Access URL — has its **own** request budget,
  stored on `Institution` (`lastSuccessfulFetch`, `dailyRequestCount`,
  `dailyRequestDate`). Because the credential syncs through iCloud Keychain,
  those counters are shared across the user's devices for that bank, but never
  between banks. Automatic refresh is gated behind a minimum interval, manual
  refresh is the only override, and the UI shows the smallest remaining budget
  across all banks. The counters ride the same CloudKit last-writer-wins
  database as everything else, so two devices syncing at the same moment can
  undercount by a request or two; the daily limit is a courtesy threshold, not
  an enforced quota. Range retries can also consume up to three requests.
- Pending transactions are matched to posted ones by amount, timing, and
  description similarity (never by id, which banks often change). Pending items
  that vanish are aged out after a couple of syncs.

## Testing

Pure logic — money conversion, matching, balance reconstruction, the rules
engine, error sanitization, DTO decoding, and export — is unit-tested with Swift
Testing against fixtures. Network paths are not tested against the live SimpleFIN
demo token; that is a documented manual smoke test.