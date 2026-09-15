import Foundation
import os

/// Writes sync diagnostics to the system log, which the Xcode console shows
/// while running from Xcode (filter on `cairn`). This is deliberately separate
/// from the in-app, privacy-scrubbed `DiagnosticsLog`: lines here may include
/// account names and holding symbols so investment detection can be debugged.
/// Credentials, account numbers, balances and transaction descriptions are
/// still never written.
public enum CairnConsole {
    private static let logger = Logger(subsystem: "cairn", category: "sync")

    /// Every line carries this prefix so the console can be filtered to Cairn.
    public static func log(_ message: String) {
        logger.log("[cairn] \(message, privacy: .public)")
    }
}
