# Privacy Policy

_Last updated: 2026_

Cairn is a personal finance app that runs on your device. **The Cairn project
operates no servers and collects no personal data.**

## What Cairn collects

Nothing. There is no analytics, no crash reporting, no advertising identifier,
and no third-party SDK. Cairn does not create an account for you and cannot see
your data.

## Where your data goes

- **SimpleFIN.** When you connect an institution, Cairn requests balances and
  transactions from the SimpleFIN server you choose (for example, the SimpleFIN
  Bridge or your bank's own server). That request goes directly from your device
  to that server, authorized by credentials you provide.
- **Custom-currency descriptors.** If a bank reports a custom currency such as
  miles or points, the SimpleFIN response names an HTTPS URL describing it, and
  Cairn fetches that URL once and caches it. That request goes to the host in the
  response, which therefore sees your device's IP address. It carries no
  financial data.
- **iCloud, only if you enable iCloud Sync.** Your data is stored in your own
  private CloudKit database. Financial fields (amounts, balances, descriptions,
  notes, and names) use CloudKit encrypted fields, which are end-to-end
  encrypted with keys from your iCloud Keychain. Apple can see that records
  exist and when they changed, but not their financial content. If you choose
  "This Device Only," nothing is sent to iCloud at all.
- **Apple Wallet, on-device.** If you connect Apple Wallet, Cairn reads Apple
  Card, Apple Cash, and Savings activity through FinanceKit and mirrors it into
  the same local store as everything else. That data follows the storage choice
  above: it stays on the device under "This Device Only," and joins your private
  iCloud database only if you turn iCloud Sync on.
- **On-device categorization.** Categorization runs on your device. When Apple
  Intelligence is available it may use the system model to suggest a category for
  a merchant; that work happens locally, and transaction text is not sent to a
  server. Rule-based categorization and merchant memory never leave the device
  at all.
- **No one else.** There is no Cairn backend, and no data is sold or shared.

## Credentials

Your SimpleFIN Access URL is a bearer credential. It is stored only in the
device Keychain. When iCloud Sync is on it syncs through iCloud Keychain, which
is end-to-end encrypted. When iCloud Sync is off it is stored
non-synchronizably with device-only protection and never leaves the device.

Note that turning iCloud Sync off stops *this* device from using the synced
credential, but does not remove an existing copy from iCloud Keychain, because
that copy is what your other devices sync with. Removing the connection deletes
the credential where you remove it, along with the synced copy; a device-only
copy on another device stays until you remove it there too.

## Your control

- **Export** every transaction to CSV or JSON at any time.
- **Delete All Data** removes all local data and, if sync is enabled, your data
  in iCloud. You can also revoke Cairn's access at your SimpleFIN Bridge.

## Children

Cairn is not directed at children and collects no data from anyone.

## Changes

Material changes will be noted in the repository's release history.

## Contact

Open an issue at https://github.com/sehejjain/cairn.