import Foundation

/// A small, in-memory diagnostic log for troubleshooting sync.
///
/// Privacy rules: it never records credentials, account numbers, balances,
/// amounts, or transaction descriptions. It records only sync metadata such as
/// the requested window, HTTP status, counts, and server error messages. The
/// buffer is bounded and is cleared when the app quits; the person can copy it
/// from Settings → Sync Diagnostics and share it if they want help.
public actor DiagnosticsLog {
    public static let shared = DiagnosticsLog()

    public enum Level: String, Sendable, Codable, CaseIterable {
        case info
        case warning
        case error
    }

    public struct Entry: Sendable, Identifiable, Hashable {
        public let id: UUID
        public let date: Date
        public let level: Level
        public let message: String

        public init(id: UUID = UUID(), date: Date, level: Level, message: String) {
            self.id = id
            self.date = date
            self.level = level
            self.message = message
        }
    }

    private var entries: [Entry] = []
    private let limit: Int

    public init(limit: Int = 500) {
        self.limit = limit
    }

    public func log(_ level: Level, _ message: String, now: Date = .now) {
        entries.append(Entry(date: now, level: level, message: message))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    public func snapshot() -> [Entry] { entries }

    public func clear() {
        entries.removeAll()
    }

    public func text() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return entries
            .map { "\(formatter.string(from: $0.date)) [\($0.level.rawValue.uppercased())] \($0.message)" }
            .joined(separator: "\n")
    }

    /// Counts used in tests and diagnostics summaries.
    public var count: Int { entries.count }
}

/// A tiny convenience so call sites stay readable.
public func cairnLog(_ level: DiagnosticsLog.Level, _ message: String) async {
    await DiagnosticsLog.shared.log(level, message)
}
