# Privacy Policy

_Last updated: September 20, 2026_

Cairn is a personal finance app that runs on your device. **Cairn has no
backend, and the Cairn developer does not collect your personal data.**

## What Cairn collects

Nothing for Cairn or its developer. There is no analytics, crash reporting,
advertising identifier, or third-party runtime SDK. Cairn does not create an
account for you and cannot see your data.

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
  private CloudKit database. Amounts, balances, names, descriptions, notes,
  merchant names, and dates use CloudKit encrypted fields, which are end-to-end
  encrypted with keys from your iCloud Keychain. Apple operates that database
  and can see that records exist, when they changed, and the structural metadata
  around them — which category a transaction is linked to, category icons,
  status flags such as pending or transfer, and sync times — but not their
  financial content. If you choose "This Device Only," nothing is sent to iCloud
  at all.
- **Apple Wallet, on-device.** If you connect Apple Wallet, Cairn reads Apple
  Card, Apple Cash, and Savings activity through FinanceKit and mirrors it into
  the same local store as everything else. The FinanceKit read happens on your
  device. That data then follows the storage choice above: it stays on the
  device under "This Device Only," and joins your private iCloud database only
  if you turn iCloud Sync on — where, like the rest of your data, it reaches
  Apple's servers with the financial fields end-to-end encrypted.
- **On-device categorization.** Categorization runs on your device. When Apple
  Intelligence is available it may use the system model to suggest a category for
  a merchant; that work happens locally, and transaction text is not sent to a
  server. Rule-based categorization and merchant memory never leave the device
  at all.
- **No Cairn backend.** Cairn does not sell data or share it with the Cairn
  developer. The direct SimpleFIN and optional iCloud transfers above are the
  only exceptions to data staying on your device.

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

See the [Cairn support page](https://cairn-finance.github.io/cairn/support.html)
or open an issue at https://github.com/cairn-finance/cairn.
