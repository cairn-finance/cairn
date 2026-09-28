# System surfaces

Cairn's widget and local alerts use an optional App Group configured by
`CAIRN_APP_GROUP_ID`. The shared container holds one Codable snapshot containing
only aggregate forecast status, currency code, and freshness timestamps. It
does not contain the SwiftData store, transactions, merchant names, account
names, institution names, or Keychain credentials.

The default value is suitable for simulator builds. Before a device or release
build, register the matching App Group for the signing team and override the
value in `Config/Signing.local.xcconfig`. If the identifier is missing or
unresolved, the app continues without widget data sharing.

The widget is iOS-only. It shows status and an “as of” label rather than exact
amounts or live bank data. Local alerts are opt-in from Settings, use stable
state identifiers, and are scheduled only for stale connections, forecast
risk, or confirmed-commitment changes. Cairn has no backend or remote freshness
claim.
