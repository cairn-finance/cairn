# Cairn

**Your money. Your data. No account, no server, no tracking.**

Cairn is a privacy-first personal finance app for iPhone, iPad, and Mac. It reads
balances and transactions from the bank accounts you authorize through
[SimpleFIN](https://www.simplefin.org), enriches them entirely on your device,
and — if you choose — syncs them across your devices using your own iCloud
private database.

There is no Cairn backend. Ever.

```
SimpleFIN server (Bridge or your bank)  ──►  your device  ──►  your iCloud (optional)
```

## What it does

- Connects to SimpleFIN Bridge or a bank-hosted SimpleFIN server.
- Shows accounts, balances, transactions, and net worth per currency.
- Categorizes locally with your own rules; notes, tags, and manual categories are
  never overwritten by automation.
- Finds subscriptions and other regular payments entirely on-device, with the
  expected next charge.
- Syncs across devices through your private iCloud database with **end-to-end
  encrypted financial fields** — Apple stores the record, not the amount.
- Optional Face ID / Touch ID app lock.
- Exports every transaction to CSV or JSON, and can delete everything.

## Privacy

- **No server, no analytics, no third-party SDKs.** The only network traffic is to
  the SimpleFIN server you configure.
- The SimpleFIN Access URL is a bearer credential and lives in the **Keychain**,
  never in the database or logs.
- `amountMinorUnits`, `balanceMinorUnits`, `description`, `note`, and names use
  `@Attribute(.allowsCloudEncryption)`, so they are end-to-end encrypted
  independent of Advanced Data Protection.
- Financial amounts are stored as integer minor units — exact, and never a float.

See [`docs/threat-model.md`](docs/threat-model.md) and
[`docs/privacy-policy.md`](docs/privacy-policy.md).

## Requirements

- Xcode 27 or newer
- iOS 26 / iPadOS 26 / macOS 26 deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```sh
# Generate the Xcode project from project.yml
xcodegen generate

# Run the core test suite
swift test

# Build the app (macOS)
xcodebuild -project Cairn.xcodeproj -scheme Cairn -destination 'platform=macOS' build

# Build the app (iOS simulator)
xcodebuild -project Cairn.xcodeproj -scheme Cairn \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The Xcode project is generated and not checked in. Edit `project.yml`, not the
`.xcodeproj`.

### Signing (device builds and iCloud)

The simulator needs no signing setup. To build for a device or enable iCloud
sync, put your own team and bundle identifier in a git-ignored local file — they
are never committed:

```sh
cp Config/Signing.example.xcconfig Config/Signing.local.xcconfig
# edit DEVELOPMENT_TEAM and PRODUCT_BUNDLE_IDENTIFIER, then:
xcodegen generate
```

`Config/Signing.xcconfig` (committed) holds safe defaults and pulls in that
local file via `#include?`. The CloudKit container is derived from your bundle
identifier as `iCloud.<bundle id>`, so no shared container is baked into the
repo and contributors never collide. Every configuration ships the same
entitlements (`Config/Cairn.entitlements`), so CloudKit and iCloud Keychain work
in Debug as well as Release; whether iCloud is actually used is decided at
runtime (`ubiquityIdentityToken`), with automatic local-only fallback when there
is no iCloud account.

### Running without a SimpleFIN token

Debug builds accept `--cairn-sample-data`, which loads demo accounts and
transactions so you can explore the UI:

```sh
xcodebuild ... -scheme Cairn build
xcrun simctl launch <device> <your.bundle.id> --cairn-sample-data
```

## Architecture

CairnCore is a local Swift package holding all logic — models, the SimpleFIN
client, the sync engine, security, enrichment, and export — so it can be tested
without a simulator. The app target is a thin SwiftUI layer.

See [`docs/architecture.md`](docs/architecture.md) for the full picture.

## Project status

**v0.1.0** — first release. Read-only SimpleFIN sync (Bridge and bank-hosted
servers), local rule-based categorization, notes/tags/transfers, per-currency
net worth with derived history, CSV + JSON export, Keychain-stored credentials
synced through iCloud Keychain, end-to-end-encrypted financial fields, and an
optional Face ID / Touch ID lock. Not included yet: budgets, reports, and
exchange rates.

If the console looks noisy, see
[`docs/troubleshooting.md`](docs/troubleshooting.md) — most of it is framework
logging, and it explains the two or three messages that aren't.

## Releasing

Releases are cut from `main` by pushing a `vX.Y.Z` tag. CI runs the tests,
uploads iOS and macOS builds to TestFlight, and publishes a GitHub Release with
generated notes and dSYMs:

```sh
Scripts/release.sh patch    # or minor / major
```

See [`docs/releasing.md`](docs/releasing.md) for the versioning scheme, the
required repository secrets, and the hotfix flow.

## Contributing

Contributions are welcome — please read [`CONTRIBUTING.md`](CONTRIBUTING.md) and
the [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md). Security issues: see
[`SECURITY.md`](SECURITY.md).

## License

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

Cairn is not affiliated with SimpleFIN or any financial institution.