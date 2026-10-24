# Contributing to Cairn

Thanks for helping make private personal finance software better.

## Getting set up

```sh
brew install xcodegen swiftlint
xcodegen generate
swift test
```

Edit `project.yml` and regenerate; never hand-edit `Cairn.xcodeproj` (it is
generated and git-ignored).

Simulator builds need no signing configuration. For device builds or iCloud,
copy `Config/Signing.example.xcconfig` to `Config/Signing.local.xcconfig`
(git-ignored), set your `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER`, then
run `xcodegen generate`. Add `ICLOUD_CONTAINER_ID` only if your container is not
`iCloud.<bundle id>`. Never commit team IDs, bundle identifiers, or container
names; they belong in the local file, not `project.yml`.

## Ground rules

- **No new runtime dependencies.** A zero-dependency app is part of the privacy
  promise. Discuss before proposing one.
- **Keep logic in `CairnCore`.** If it can be tested without a simulator, it
  belongs in the package, not the app target.
- **Financial content must be marked encrypted.** New persisted fields that
  contain amounts, balances, descriptions, notes, or names must use
  `@Attribute(.allowsCloudEncryption)` — the choice is irreversible after a
  Production CloudKit deploy.
- **Respect provenance.** Automation (rules, future on-device models) must never
  write user-owned fields (`userCategory`, `note`, `tags`, `isTransfer`,
  `isIgnored`).
- **Never log secrets.** Access URLs and amounts are off-limits in logs; use
  `os_log` privacy markers.
- **HTTPS only.** Never relax transport security.

## Tests

Add tests for any pure logic you change — money conversion, matching, balance
history, rules, sanitization, decoding, export. Do not point tests at the live
SimpleFIN demo token; use the `URLProtocol` stubs.

CI checks all GitHub Actions workflows with actionlint, including embedded shell
and Python scripts. For local workflow checks, run `actionlint` from the
repository root. Custom runner labels are listed in `.github/actionlint.yaml`.

## Pull requests

- Keep changes focused and explain the "why".
- Run `swift test` and build both platforms before opening a PR.
- Update docs when behavior or the schema changes.
- Maintainers: see [`docs/releasing.md`](docs/releasing.md) before tagging a
  release.

## Inactive issues

Unassigned issues with no activity for 60 days receive a `stale` label and a
reminder. After another 14 days without activity, they are closed as not planned.
An update or comment before closure removes the label on the next daily run and
restarts the inactivity timer. If a closed issue still needs attention, comment
with an update so a maintainer can reopen it.

Issues with an assignee or milestone are exempt, as are issues labeled
`confirmed`, `enhancement`, `security`, `pinned`, or `keep-open`. Use `confirmed`
for a verified bug or `keep-open` for another issue that should remain active
without periodic reminders. Pull requests are excluded.

Maintainers can preview the daily workflow from **Actions → Manage stale issues
→ Run workflow**. Leave **dry_run** enabled to see the proposed changes without
updating issues. Scheduled runs apply changes automatically after the workflow
is merged into the default branch.

## Commit messages

Short (under ~60 words), imperative, and scoped.

## License

By contributing you agree your work is licensed under Apache-2.0.
