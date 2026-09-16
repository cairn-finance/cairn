import Foundation

/// A sendable snapshot of a persisted rule, so the pure rules engine never
/// touches SwiftData model objects.
public struct RuleSnapshot: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let field: RuleField
    public let matchKind: RuleMatchKind
    public let pattern: String
    public let minAmountMinorUnits: Int64?
    public let maxAmountMinorUnits: Int64?
    public let categoryID: UUID
    public let priority: Int

    public init(
        id: UUID,
        field: RuleField,
        matchKind: RuleMatchKind,
        pattern: String,
        minAmountMinorUnits: Int64? = nil,
        maxAmountMinorUnits: Int64? = nil,
        categoryID: UUID,
        priority: Int = 0
    ) {
        self.id = id
        self.field = field
        self.matchKind = matchKind
        self.pattern = pattern
        self.minAmountMinorUnits = minAmountMinorUnits
        self.maxAmountMinorUnits = maxAmountMinorUnits
        self.categoryID = categoryID
        self.priority = priority
    }
}

/// Local, deterministic categorization. Rules are evaluated by descending
/// priority; the first match wins. No network, no data leaves the device.
public enum RulesEngine {
    /// Returns the category id assigned by the highest-priority matching rule.
    public static func categoryID(
        amountMinorUnits: Int64,
        description: String,
        rules: [RuleSnapshot]
    ) -> UUID? {
        let ordered = rules.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.pattern.count > $1.pattern.count
        }

        for rule in ordered {
            guard matches(rule, amountMinorUnits: amountMinorUnits, description: description) else {
                continue
            }
            return rule.categoryID
        }
        return nil
    }

    /// Whether one rule's condition matches a transaction. Exposed so the rule
    /// editor can preview a draft without duplicating the matching logic.
    public static func matches(_ rule: RuleSnapshot, amountMinorUnits: Int64, description: String) -> Bool {
        if let min = rule.minAmountMinorUnits, amountMinorUnits < min { return false }
        if let max = rule.maxAmountMinorUnits, amountMinorUnits > max { return false }

        switch rule.field {
        case .amount:
            // Amount rules with no explicit bounds would match everything; treat
            // the pattern as an exact amount when present at the rule's precision.
            if rule.pattern.isEmpty { return true }
            guard let target = MinorUnits.parse(rule.pattern, exponent: 2) else { return false }
            return amountMinorUnits == target
        case .payee:
            return matchesText(rule, description: description)
        }
    }

    private static func matchesText(_ rule: RuleSnapshot, description: String) -> Bool {
        let pattern = rule.pattern
        guard !pattern.isEmpty else { return false }

        switch rule.matchKind {
        case .contains:
            return description.range(of: pattern, options: .caseInsensitive) != nil
        case .beginsWith:
            return description.range(of: pattern, options: [.caseInsensitive, .anchored]) != nil
        case .endsWith:
            return description.lowercased().hasSuffix(pattern.lowercased())
        case .equals:
            return description.compare(pattern, options: .caseInsensitive) == .orderedSame
        case .regularExpression:
            // Rules are re-evaluated for every transaction, so the pattern is
            // compiled once per process rather than twice per transaction.
            guard let regex = RegexCache.shared.regex(for: pattern) else { return false }
            let range = NSRange(description.startIndex..<description.endIndex, in: description)
            return regex.firstMatch(in: description, range: range) != nil
        }
    }
}

/// A small, bounded cache of compiled regular expressions for regex rules.
///
/// `NSRegularExpression` is immutable and thread-safe, so sharing compiled
/// instances behind a lock is safe. The cache is cleared rather than grown
/// without bound when a person edits many patterns.
private final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()

    private let lock = NSLock()
    private var compiled: [String: NSRegularExpression] = [:]
    private var invalid: Set<String> = []
    private let limit = 128

    func regex(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }

        if let hit = compiled[pattern] { return hit }
        if invalid.contains(pattern) { return nil }

        if compiled.count + invalid.count >= limit {
            compiled.removeAll()
            invalid.removeAll()
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            invalid.insert(pattern)
            return nil
        }
        compiled[pattern] = regex
        return regex
    }
}

public extension RuleSnapshot {
    /// Whether this rule's condition matches a transaction, ignoring the
    /// category it assigns. Used by the rule editor to preview its effect.
    func matches(amountMinorUnits: Int64, description: String) -> Bool {
        RulesEngine.matches(self, amountMinorUnits: amountMinorUnits, description: description)
    }
}
