# Threat model

Cairn exists to shrink the number of parties who can see your financial life.
This document states honestly who they are.

## Assets

| Asset | Sensitivity |
| --- | --- |
| SimpleFIN Access URL | Bearer credential — grants read access to your bank data |
| Account balances and transactions | Financial behavior |
| Categories, notes, tags | Your annotations about your behavior |
| SimpleFIN setup token | One-time; compromised token means someone else can read your data |

## Trust parties

| Party | Sees | Notes |
| --- | --- | --- |
| You | Everything | You hold the device and the SimpleFIN login |
| SimpleFIN (Bridge or your bank's server) | Full account data | Required to fetch it |
| Your bank | Full account data | Original source |
| Apple (iCloud), **only if you enable sync** | Record existence, timestamps, and *unencrypted* metadata | Financial fields are end-to-end encrypted; see below |

If you choose **This Device Only**, Apple is removed from the trust set entirely
and your credential is stored non-synchronizably.

## What protects each asset

- **Access URL** — stored in the Keychain with
  `kSecAttrAccessibleAfterFirstUnlock`. Apple's checklist requires credentials be
  stored at least as securely as the financial data. The URL is never written to
  SwiftData, logs, or URLs that are transmitted.
- **Financial content** — `@Attribute(.allowsCloudEncryption)` for amounts,
  balances, descriptions, notes, and names. These are encrypted with keys from
  your iCloud Keychain, independent of Advanced Data Protection. Apple can see
  that a record exists and when it changed, but not its financial content.
- **Transport** — HTTPS only, with the platform's default certificate
  verification. No certificate pinning (SimpleFIN endpoints vary).
- **At rest** — iOS/macOS Data Protection; the store is not separately encrypted
  with a user passphrase.

## What this does NOT protect against

- **A stolen, unlocked device.** The optional app lock gates the UI, not the
  Keychain item. `AfterFirstUnlock` accessibility is required so background sync
  can run. If a device is taken while unlocked, revoke access at your SimpleFIN
  Bridge.
- **A compromised SimpleFIN account.** Whoever holds your SimpleFIN credentials
  can read your bank data; Cairn cannot change that.
- **Apple, if you enable sync and do not enable Advanced Data Protection.**
  Field-level encryption protects the financial content, but record metadata and
  non-encrypted fields remain visible. Enable ADP for defense in depth.
- **Malicious server text.** All messages from SimpleFIN are sanitized (markup
  and control characters stripped, length capped) before display.

## Recommendations

- Enable **Advanced Data Protection** for your Apple Account.
- Use a device passcode and, ideally, the app lock.
- Revoke unused SimpleFIN tokens at the Bridge.
- Prefer **This Device Only** if you do not need multi-device sync.

## Reporting

See [`SECURITY.md`](../SECURITY.md).