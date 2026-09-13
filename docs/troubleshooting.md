# Known console output

Cairn uses SwiftData + CloudKit, Swift Charts, and Liquid Glass, and it runs in
the macOS/iOS sandbox. Several of those systems emit log lines that look alarming
but are not faults. This page separates the noise from the real ones.

## Expected, non-fatal

| Message | What it is |
| --- | --- |
| `updateTaskRequest failed for com.apple.coredata.cloudkit.activity.export … BGSystemTaskSchedulerErrorDomain Code=3` | Core Data's internal CloudKit export scheduler. It requests a background task the system declines (common on macOS and in unsigned builds). Sync still runs while the app is active. Appears in bursts after launch. |
| `updateTaskRequest called for a pre-running task …` / `… already running/updated task …` | The same scheduler noting it will not queue a duplicate. Benign. |
| `cannot add handler to 0 from 0 - dropping` | Network.framework noise from CloudKit's background networking. Benign and very common. |
| `non-launching port is incompatible with service identifier "com.apple.PointerUI…"` | System/Xcode noise, unrelated to Cairn. |
| `sandbox_extension_issue_file failed for /simplefin/create` | macOS LaunchServices issuing a sandbox extension when the SimpleFIN page is opened. The browser still opens normally. |
| `fopen failed for data file: errno = 2 (No such file or directory)` | Core Data / CoreSpotlight bookkeeping. Benign. |
| `invalid mode 'kCFRunLoopCommonModes' provided to CFRunLoopRunSpecific` | Framework noise; the message is emitted once per execution. |
| `Snapshotting a view (_UINavigationBarLargeTitleView) … afterScreenUpdates:YES` | UIKit screenshot tooling (Xcode / the device-interaction harness), not application code. |
| `glassEffect() tried to update multiple times per frame.` | SwiftUI Liquid Glass reacting to rapid state updates. Cosmetic. |
| `Charts: Custom UnitPoint values are not supported in AxisValueLabel's anchor property` | Emitted by Swift Charts itself. It appears even when the chart uses only default axes, so it is a framework-level message and not caused by Cairn's chart code. |
| `CoreData: debug: WAL checkpoint …` | Normal SwiftData/Core Data maintenance. |

## Real problems and what to check

### Data or credentials aren't syncing between devices

Two independent channels must both work:

- **CloudKit** syncs the database (institutions, accounts, transactions).
- **iCloud Keychain** syncs the SimpleFIN Access URL, keyed by `credentialID`.

Check, on both devices:

1. **Settings → Storage** shows **iCloud Sync** with no fallback note. If it shows
   a fallback reason, the build has no iCloud entitlement or the CloudKit
   container isn't registered for your team.
2. The CloudKit container `iCloud.<your bundle id>` exists under your team and
   iCloud → CloudKit is enabled for the App ID.
3. Everyone is signed into the **same Apple Account**, with **iCloud Drive** and
   **iCloud Keychain ("Passwords and Keychain")** enabled.
4. The build is signed with your team. `ubiquityIdentityToken` is `nil` for
   unsigned builds, so Cairn deliberately keeps data local and the data
   protection keychain returns `errSecMissingEntitlement (-34018)`.

To force local-only storage for testing, launch with `-cairn-disable-cloudkit`.

### Keychain error `-34018`

`errSecMissingEntitlement` means the running build is not signed with an iCloud
team identity (for example `CODE_SIGNING_ALLOWED=NO` CI/compile-only builds, or
an ad-hoc build). Build and run from Xcode with your team configured in
`Config/Signing.local.xcconfig`.
