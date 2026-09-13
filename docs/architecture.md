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
   ├─ Enrichment/    rules engine
   └─ Export/        CSV + JSON
```

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
and bundle identifier. The entitlement references
`iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)`, and the runtime derives the same value, so
each developer gets their own `iCloud.<bundle id>` container instead of a shared
one. Register that container (and enable CloudKit on the App ID) before using
Release builds that sync through iCloud.

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
- **Encrypted fields**: financial content uses
  `@Attribute(.allowsCloudEncryption)`. Encryption status is irreversible after a
  Production schema deploy, so it is fixed in schema version 1.
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
  across all banks.
- Pending transactions are matched to posted ones by amount, timing, and
  description similarity (never by id, which banks often change). Pending items
  that vanish are aged out after a couple of syncs.

## Testing

Pure logic — money conversion, matching, balance reconstruction, the rules
engine, error sanitization, DTO decoding, and export — is unit-tested with Swift
Testing against fixtures. Network paths are not tested against the live SimpleFIN
demo token; that is a documented manual smoke test.