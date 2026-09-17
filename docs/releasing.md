# Releasing Cairn

Cairn ships from `main`. A git tag is the single source of truth for a release:
pushing `vX.Y.Z` runs [`.github/workflows/release.yml`](../.github/workflows/release.yml),
which tests, archives, uploads to TestFlight, and publishes a GitHub Release.

## Version numbers

Two numbers come out of every release:

| Info.plist key | Xcode setting | Source |
| --- | --- | --- |
| `CFBundleShortVersionString` | `MARKETING_VERSION` | the tag, without the `v` (`v0.1.0` → `0.1.0`) |
| `CFBundleVersion` | `CURRENT_PROJECT_VERSION` | `git rev-list --count HEAD` at the tag |

The build number must strictly grow for App Store Connect to accept a build.
Commit count is deterministic, always increases along `main`, and keeps a re-run
of the same tag on the same build number.

`project.yml` carries a `MARKETING_VERSION` default for local development.
`Scripts/release.sh` updates it; CI overrides both numbers on the `xcodebuild`
command line, so the tag always wins. **Never** edit versions in the generated
`.xcodeproj` — XcodeGen rewrites it.

## CloudKit schema promotions

CloudKit fixes a field's encryption setting when the schema is deployed to
Production. It can never be flipped afterwards, in either direction, and a
field's type cannot be changed either. So "add it plaintext now, encrypt it
later" is impossible without a parallel `…Encrypted` field and a data migration:
the encryption attribute is part of the field's type.

Every change to `Sources/CairnCore/Models` therefore has to reach Production
**before** the release that carries it. `Scripts/schema-hash.sh --check` — run by
CI on every push and pull request, and again by the release workflow — fails
until the current schema is recorded in `Config/schema-promotions.txt`. That is
deliberate: a failing check is the reminder that a deployment is outstanding.

The order matters, because the last step cannot be undone:

1. **Create the container.** In the developer portal, create the CloudKit
   container and enable **iCloud → CloudKit** for the App ID. Cairn's own
   container is not derived from the bundle id, so it is set explicitly — see
   [Where the container comes from](#where-the-container-comes-from).
2. **Point your build at it.** Add `ICLOUD_CONTAINER_ID` to
   `Config/Signing.local.xcconfig` (git-ignored):
   `ICLOUD_CONTAINER_ID = <the container you just created>`.
3. **Declare the whole schema at once, from a clean install.** Run a **Debug**
   build with the `-cairn-initialize-cloudkit-schema` launch argument, on a
   **fresh simulator or a clean install — never on a device that holds real
   data**:

   ```sh
   xcodebuild -project Cairn.xcodeproj -scheme Cairn -configuration Debug \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
   # then launch once with the argument (Xcode: Edit Scheme → Run → Arguments)
   ```

   The initializer builds its own `NSPersistentCloudKitContainer` over a
   throwaway store in the temporary directory, calls
   `initializeCloudKitSchema(options:)`, logs the result, and exits. It walks the
   entire managed object model, so every record type and every field is declared
   **whether or not a value exists for it** — the optional columns that a normal
   run leaves nil would otherwise never appear, and a field missing from the
   deploy cannot be added as encrypted later.

   It never opens the app's own store, so no sample data and no old mirroring
   metadata can reach the new container. That is also why you must not do this on
   a device with real data: the app itself would be pointed at the new container.

   You do **not** need to turn on iCloud Sync first. Sync is opt-in, and the
   initializer talks to CloudKit directly rather than through the app's store —
   it only needs a signed-in iCloud account.
4. **Confirm encryption in Development.** In **CloudKit Console → your container
   → Schema**, stay on **Development** and check that every field that should be
   encrypted reports as encrypted: `payeeDescription`, `amountMinorUnits`, `note`,
   `normalizedMerchant`, `postedDate`, `transactedAt`, the rule amount bounds,
   `orgID`/`orgURL`/`sfinURL`, `lastSyncError`, the account and holding names,
   `currencyCode`, `accountTypeRaw`, and the custom-currency names. If any is
   plaintext, fix the model and reset the Development schema — Development resets
   as often as you like.
5. **Deploy to Production.** Only now choose **Deploy Schema Changes**.
6. **Record it.** `Scripts/schema-hash.sh --record "what changed"`, then commit.
   This is what turns CI green.

A new container needs steps 2–6 even when no model changed, because the hash
cannot see the container name.

Skipping this does not fail loudly on the release itself: TestFlight keeps
working against the old schema until a record carrying a new field is written,
and then CloudKit rejects the export and iCloud Sync silently stops making
progress.

## Where the container comes from

One build setting, `ICLOUD_CONTAINER_ID`, defines the CloudKit container. It is
written into the entitlement (`com.apple.developer.icloud-container-identifiers`)
and into `CairnCloudKitContainerID` in `Info.plist`, which
`ModelContainerFactory` reads at runtime. The container the app requests and the
container it is entitled to therefore cannot disagree.

It defaults to `iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)` in `Config/Signing.xcconfig`,
so a fresh clone uses its own container. Override it in
`Config/Signing.local.xcconfig` — or in CI, from the `ICLOUD_CONTAINER_ID`
secret — when the container is not derived from the bundle id, which is the case
for any container created before the bundle id settled.

## Cut a release

```sh
git checkout main && git pull
Scripts/release.sh patch     # or minor / major / an explicit X.Y.Z
```

The script verifies you are on a clean `main`, computes the next version,
prepends a `CHANGELOG.md` entry, commits, tags `vX.Y.Z`, and pushes. CI does the
rest. Watch it under the repository's **Actions → Release** tab.

The tag must be contained in `main`; the workflow refuses anything else.

## What CI does

1. **Prepare** — refuses a tag that is not on `main`, runs `swift test` and
   `swiftlint`, refuses a schema that was never deployed to Production, and
   computes the version/build pair.
2. **Archive** (matrix: iOS and macOS) — writes the signing config and App Store
   Connect API key from secrets, generates the project, archives Release with
   `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, then exports with
   `method=app-store-connect`, `destination=upload` to send the build straight to
   TestFlight. dSYMs are collected as artifacts.
3. **Publish** — creates the GitHub Release with generated notes and attaches the
   dSYM zips.

## Required repository secrets

Add these under **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `DEVELOPMENT_TEAM` | your 10-character Team ID |
| `PRODUCT_BUNDLE_IDENTIFIER` | the app's bundle id (must match the App ID) |
| `ICLOUD_CONTAINER_ID` | the CloudKit container to sync through, e.g. `iCloud.com.example.cairn.sync` |
| `APPSTORE_API_KEY_ID` | the App Store Connect API key's Key ID |
| `APPSTORE_API_ISSUER_ID` | the key's Issuer ID |
| `APPSTORE_API_PRIVATE_KEY` | the `.p8` file, **base64-encoded** |

Create the key in **App Store Connect → Users and Access → Integrations → App
Store Connect API**. Automatic signing has to create certificates and
provisioning profiles, so use a key with access to Certificates, Identifiers &
Profiles — an **Admin** key is the safe choice (an App Manager key may not be
enough).

Encode the key without line wrapping:

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy   # paste into APPSTORE_API_PRIVATE_KEY
```

CI decorates the build with `-allowProvisioningUpdates` and the API key, so no
certificates or provisioning profiles are stored anywhere.

## One-time App Store Connect setup

Before the first tag can upload, the surrounding Apple configuration must exist
(the workflow can create profiles, not accounts):

- An **App Store Connect app record** for the bundle id, with both the iOS and
  macOS platforms. One bundle id serves both — Cairn is a single target with
  `supportedDestinations: [iOS, macOS]`.
- The App ID enabled for **iCloud → CloudKit**, with the container named by
  `ICLOUD_CONTAINER_ID` created (it defaults to `iCloud.<bundle id>`). Cloud
  signing creates profiles, not containers, so create it in the developer portal
  and enable iCloud for the App ID there. See [Where the container comes
  from](#where-the-container-comes-from).
- TestFlight groups/testers configured as you like; the build appears under
  **App Store Connect → TestFlight**.

App Store Connect requires uploads built with **Xcode 26 or later** (since
April 2026); the workflow runs on `macos-26` with Xcode 27.

## Release branches and hotfixes

Cairn is trunk-based: `main` is always releasable and tags mark versions. You do
not need a long-lived release branch for normal releases. When you must patch an
already-shipped version while `main` has moved on:

```sh
git checkout -b release/0.1.1 v0.1.0   # branch from the release you're fixing
# ...make the fix, commit...
git checkout main
git merge --no-edit release/0.1.1       # land it on main first
git tag v0.1.1 && git push origin main v0.1.1
git branch -d release/0.1.1
git push origin --delete release/0.1.1
```

Merging the fix back to `main` keeps the branches from diverging. If you prefer,
run `Scripts/release.sh 0.1.1` on `main` after merging instead of tagging by
hand.

## Re-running a release

If an upload fails transiently, re-run the failed job from the Actions tab. The
build number is derived from the commit, so the re-run reuses the same number:
App Store Connect only rejects it if the first attempt actually succeeded. If it
did succeed and you truly need a new build, make a new commit and tag a patch.

To pull a broken GitHub Release, delete it and re-run the workflow:

```sh
gh release delete v0.1.1 --yes
```

## Troubleshooting

- **"Cloud signing permission error" / no profiles** — the API key lacks access
  to Certificates, Identifiers & Profiles. Use an Admin key, or create the App ID
  and a distribution certificate manually first.
- **macOS export asks for installer signing** — the app needs a *Mac Installer
  Distribution* certificate. Cloud signing creates one when the API key can
  manage certificates; otherwise create it in the portal once.
- **CloudKit container missing** — cloud signing creates provisioning profiles,
  not CloudKit containers. Create the container named by `ICLOUD_CONTAINER_ID` in
  the developer portal and enable iCloud for the App ID.
- **iCloud Sync stops making progress after a release** — a new field reached
  TestFlight before the schema was deployed to Production, so CloudKit rejects the
  records that carry it. Deploy the schema (see [CloudKit schema
  promotions](#cloudkit-schema-promotions)), run
  `Scripts/schema-hash.sh --record`, and commit.
- **Duplicate build number** — re-running a tag that already uploaded will be
  rejected by App Store Connect. Make a new commit and tag a patch version.

