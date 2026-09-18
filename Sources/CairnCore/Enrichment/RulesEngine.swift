import Dispatch
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

    /// How long one regular-expression rule may take before it is abandoned.
    ///
    /// Generous for a merchant pattern — which matches in microseconds — and
    /// short enough that a pathological one cannot stall a pass over thousands of
    /// transactions.
    static let regexBudget: DispatchTimeInterval = .milliseconds(50)

    /// A merchant pattern has no business being longer than this.
    static let maxPatternLength = 200

    /// Regex patterns abandoned for exceeding ``regexBudget`` during this
    /// process, so the app can point the person at the rule to rewrite.
    public static var disabledPatterns: Set<String> {
        RegexCache.shared.disabledPatterns
    }

    /// Why a pattern is unsuitable, phrased for the rule editor, or `nil` when it
    /// is fine. Lives here so the editor and the matcher agree on what is allowed.
    public static func patternProblem(_ pattern: String) -> String? {
        if pattern.count > maxPatternLength {
            return "That pattern is too long — keep it under \(maxPatternLength) characters."
        }
        if !isSafePattern(pattern) {
            return "That pattern repeats itself without a limit, which would stall "
                + "categorization. Remove a nested repeat such as (a+)+ or ([0-9]*)*."
        }
        return nil
    }

    /// Whether a pattern is worth letting a person save.
    ///
    /// Rejects the shape that gives a backtracking engine exponential work — a
    /// group that already holds an unbounded quantifier, itself quantified:
    /// `(a+)+`, `([0-9]*)*` — and anything longer than a merchant name has any
    /// reason to be. No heuristic catches everything, which is why the deadline
    /// in ``matchesRegex(_:description:)`` is the actual guard; this only keeps
    /// the obvious footguns out of the database. It is applied when a rule is
    /// saved, never to rules that already exist.
    public static func isSafePattern(_ pattern: String) -> Bool {
        guard pattern.count <= maxPatternLength else { return false }

        var groupHasQuantifier: [Bool] = []
        var inCharacterClass = false
        var escaped = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            let next = pattern.index(after: index)

            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if inCharacterClass {
                if character == "]" { inCharacterClass = false }
            } else {
                switch character {
                case "[":
                    inCharacterClass = true
                case "(":
                    groupHasQuantifier.append(false)
                case ")":
                    let inner = groupHasQuantifier.popLast() ?? false
                    if inner, next < pattern.endIndex, isUnboundedQuantifier(pattern, at: next) {
                        return false
                    }
                    if let last = groupHasQuantifier.indices.last {
                        groupHasQuantifier[last] = groupHasQuantifier[last] || inner
                    }
                case "*", "+":
                    if let last = groupHasQuantifier.indices.last {
                        groupHasQuantifier[last] = true
                    }
                case "{":
                    if isUnboundedQuantifier(pattern, at: index), let last = groupHasQuantifier.indices.last {
                        groupHasQuantifier[last] = true
                    }
                default:
                    break
                }
            }
            index = next
        }
        return true
    }

    /// Whether the quantifier starting at `index` is unbounded — `*`, `+`, or a
    /// `{n,}` with no upper bound. Bounded repetition can be slow too, which is
    /// what the deadline is for.
    private static func isUnboundedQuantifier(_ pattern: String, at index: String.Index) -> Bool {
        switch pattern[index] {
        case "*", "+":
            return true
        case "{":
            guard let closing = pattern[index...].firstIndex(of: "}") else { return false }
            return pattern[pattern.index(after: index)..<closing].hasSuffix(",")
        default:
            return false
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
            return matchesRegex(pattern, description: description)
        }
    }

    /// Evaluates a regex rule under a deadline.
    ///
    /// Rules are re-evaluated for every transaction, so the pattern is compiled
    /// once per process (`RegexCache`) and evaluated off the caller's thread, so
    /// that one pattern taking an unreasonable amount of time cannot stall the
    /// whole pass. `NSRegularExpression` offers no timeout and cannot be
    /// cancelled, so the abandoned evaluation is left to finish on its own and
    /// the pattern is disabled for the rest of the process: it costs one
    /// overrun, not one per transaction.
    private static func matchesRegex(_ pattern: String, description: String) -> Bool {
        guard let regex = RegexCache.shared.regex(for: pattern) else { return false }

        let pending = PendingRegexMatch(
            regex: regex,
            text: description,
            range: NSRange(description.startIndex..<description.endIndex, in: description)
        )
        RegexCache.shared.queue.async { pending.run() }
        guard let matched = pending.result(within: regexBudget) else {
            RegexCache.shared.disable(pattern)
            return false
        }
        return matched
    }
}

/// A one-shot regex evaluation that the caller can walk away from.
///
/// `NSRegularExpression` is neither `Sendable` nor cancellable, so the whole
/// evaluation travels inside this wrapper and only ever runs on one thread at a
/// time. A pattern that blows its budget leaves one thread finishing work whose
/// result nobody reads — which is why ``RulesEngine/disabledPatterns`` exists, so
/// it can only happen once per pattern.
private final class PendingRegexMatch: @unchecked Sendable {
    private let regex: NSRegularExpression
    private let text: String
    private let range: NSRange
    private let finished = DispatchSemaphore(value: 0)
    private var matched = false

    init(regex: NSRegularExpression, text: String, range: NSRange) {
        self.regex = regex
        self.text = text
        self.range = range
    }

    func run() {
        matched = regex.firstMatch(in: text, range: range) != nil
        finished.signal()
    }

    /// The result, or `nil` when the budget runs out first. The semaphore orders
    /// the write in `run()` before this read, so no lock is needed.
    func result(within budget: DispatchTimeInterval) -> Bool? {
        guard finished.wait(timeout: .now() + budget) == .success else { return nil }
        return matched
    }
}

/// A small, bounded cache of compiled regular expressions for regex rules.
///
/// `NSRegularExpression` is immutable and thread-safe, so sharing compiled
/// instances behind a lock is safe. The cache is cleared rather than grown
/// without bound when a person edits many patterns.
private final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()

    /// Evaluations run here, concurrently, so one slow pattern cannot block the
    /// next rule and never occupies the caller's thread for longer than the
    /// deadline allows.
    let queue = DispatchQueue(label: "com.sehej.cairn.rules.regex", attributes: .concurrent)

    private let lock = NSLock()
    private var compiled: [String: NSRegularExpression] = [:]
    private var invalid: Set<String> = []
    /// Patterns that overran the deadline. Kept for the process, so a
    /// pathological pattern is evaluated once rather than on every transaction.
    private var disabled: Set<String> = []
    private let limit = 128

    func regex(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }

        if disabled.contains(pattern) { return nil }
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

    func disable(_ pattern: String) {
        lock.lock()
        defer { lock.unlock() }
        disabled.insert(pattern)
        compiled[pattern] = nil
    }

    var disabledPatterns: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return disabled
    }
}

public extension RuleSnapshot {
    /// Whether this rule's condition matches a transaction, ignoring the
    /// category it assigns. Used by the rule editor to preview its effect.
    func matches(amountMinorUnits: Int64, description: String) -> Bool {
        RulesEngine.matches(self, amountMinorUnits: amountMinorUnits, description: description)
    }
}
