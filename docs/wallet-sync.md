# Apple Wallet data and iCloud sync

Apple Wallet accounts and transactions are `Account` and `LedgerTransaction`
rows with `sourceRaw == financeKit`. They live in the same store as everything
else, so they sync through CloudKit with the rest of the ledger. FinanceKit
authorization, on the other hand, is granted **per device**: an iPhone can read
Apple Card while a Mac cannot read Wallet at all.

Those two facts disagree, and this note records the disagreement, the options,
and what still needs deciding.

## What goes wrong today

1. On the Mac, "Remove Apple Wallet data" deletes the Wallet rows locally.
2. Those deletions sync to every device, so the iPhone loses the same rows.
3. The iPhone still has FinanceKit access and Wallet sync on, so its next Wallet
   sync imports the same cards again — as new rows, with new identities, because
   CloudKit record names are per object.
4. The re-imported rows sync back to the Mac.

So the Mac's removal does not stick, and every cycle throws away anything the
person attached to those rows — a corrected category, a note, a tag — because the
rows are new objects each time. The same mechanism can duplicate a card if two
authorized devices import it with different account keys.

## Why the obvious fixes do not work

**Exclude Wallet rows from CloudKit.** CloudKit mirroring is per *entity*, not per
row, and `Account`/`LedgerTransaction` are shared with SimpleFIN and manual
accounts. Excluding Wallet rows therefore means splitting the model — separate
`WalletAccount`/`WalletTransaction` entities in a local-only store — and then
teaching every reader (accounts, net worth, insights, search, CSV import, the
sync engine) to union across two entity families, plus a migration for existing
rows. Large, and it splits the ledger the person sees, for a feature that already
works on the device that owns the data.

**Keep deleting, but only rows this device read.** Scoping the delete to
`WalletAccountRetention.previouslySeen()` stops the Mac from deleting rows the
iPhone owns, which removes the churn — but on a Mac the seen set is empty, so the
action becomes a no-op and the button lies.

**Hide them locally instead of deleting.** Correct in principle, but "hidden"
cannot be a model field (a synced field would hide them on the iPhone too, which
is still authorized and still wants them), so it has to be device-local state
consulted by every read that touches accounts or transactions. Same breadth as
the entity split, without fixing the identity duplication.

## The two coherent designs

**A. Treat Wallet data as per-device.** Wallet rows never sync (entity split
above). Disconnect is then a purely local action and sticks by construction. Cost
is the model split and the migration; benefit is that a Mac simply never sees the
iPhone's Wallet rows.

**B. Treat Wallet tracking as a shared intent (recommended).** Keep the rows
synced, and make "Cairn tracks Apple Wallet" a *synced* preference rather than a
device-local one, so turning it off anywhere is honoured everywhere:

- The preference moves into the synced store (an `AppSettings` flag, plaintext
  like the other flags) instead of `UserDefaults`.
- Turning it off deletes the Wallet rows once, from a device that actually read
  them, and no other device re-imports — so the deletion sticks everywhere.
- Turning it on is a per-device read decision: each device imports whatever *its*
  authorization allows, which is what `WalletAvailability.isSupported` already
  gates.

That is a small change and it matches what a person means by "remove my Wallet
data" — one intent, applied everywhere. It costs a schema change (one flag field),
which means another CloudKit promotion before it ships; the tooling for that is
now in place (`-cairn-initialize-cloudkit-schema`, `Scripts/schema-hash.sh`).

`NSUbiquitousKeyValueStore` could carry the flag without touching the schema, but
it is a second, less reliable sync mechanism, and this flag gates a deletion — the
durable store is the right home for it.

## Still open

- **Are FinanceKit account and transaction identifiers stable across devices?**
  Nothing in FinanceKit's documentation promises it. If two authorized devices
  produce different keys for one card, design B still leaves two accounts in the
  ledger unless the key is derived from something stable (issuer, display name,
  last four digits). Worth checking before relying on the keys: authorize Wallet
  on the iPhone, note the account key or the account's displayed balance, and
  compare with what a Mac sees in `Account.bankAccountID` for the same card.
- Whether the Wallet "Remove" affordance should exist on a Mac at all. Under
  design A it should not; under design B it is the natural place to turn the
  shared intent off.

## Interim decision

Until a synced preference (design B) exists, the Mac does not offer "Remove
Apple Wallet data". The row and its "Updates on your iPhone" subtitle still
appear, so the data is visible and explained, but a removal started on the Mac
cannot stick while an iPhone is authorized and would discard notes, tags, and
categories on the rows the iPhone re-imports.

The action still appears on iPhone and iPad, but that is a **known limitation
rather than a guarantee**: when an iPhone is authorized, a removal started on an
iPad cannot stick either — the iPhone re-imports the same cards as new rows,
discarding notes, tags, and categories. Removal only sticks while no other
authorized device re-imports the cards. Revisit when the shared preference (or
the entity split) lands.
