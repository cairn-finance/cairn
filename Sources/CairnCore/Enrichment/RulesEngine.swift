import Dispatch
import Foundation
import SwiftData

/// A sendable snapshot of a persisted rule, so the pure rules engine never
/// touches SwiftData model objects.
public struct RuleSnapshot: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let field: RuleField
    public let matchKind: RuleMatchKind
    public let pattern: String
    public let minAmountMinorUnits: Int64?
    public let maxAmountMinorUnits: Int64?
    public let categoryID: UUID?
    public let priority: Int
    public let displayNameTemplate: String?
    public let makesCompact: Bool
    public let appliedTagIDs: [PersistentIdentifier]

    public init(
        id: UUID,
        field: RuleField,
        matchKind: RuleMatchKind,
        pattern: String,
        minAmountMinorUnits: Int64? = nil,
        maxAmountMinorUnits: Int64? = nil,
        categoryID: UUID? = nil,
        priority: Int = 0,
        displayNameTemplate: String? = nil,
        makesCompact: Bool = false,
        appliedTagIDs: [PersistentIdentifier] = []
    ) {
        self.id = id
        self.field = field
        self.matchKind = matchKind
        self.pattern = pattern
        self.minAmountMinorUnits = minAmountMinorUnits
        self.maxAmountMinorUnits = maxAmountMinorUnits
        self.categoryID = categoryID
        self.priority = priority
        self.displayNameTemplate = displayNameTemplate
        self.makesCompact = makesCompact
        self.appliedTagIDs = appliedTagIDs
    }
}

public struct RuleEffects: Sendable, Equatable {
    public let matchingRuleIDs: [UUID]
    public let categoryID: UUID?
    public let displayName: String?
    public let makesCompact: Bool
    public let appliedTagIDs: [PersistentIdentifier]
}

/// Local, deterministic rule evaluation. Every matching rule contributes an
/// action; the highest-priority rule wins when category or name conflicts.
public enum RulesEngine {
    /// Returns the category id assigned by the highest-priority matching rule.
    public static func categoryID(
        amountMinorUnits: Int64,
        description: String,
        rules: [RuleSnapshot]
    ) -> UUID? {
        effects(amountMinorUnits: amountMinorUnits, description: description, rules: rules).categoryID
    }

    public static func effects(
        amountMinorUnits: Int64,
        description: String,
        rules: [RuleSnapshot]
    ) -> RuleEffects {
        let ordered = rules.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.pattern.count != $1.pattern.count { return $0.pattern.count > $1.pattern.count }
            return $0.id.uuidString < $1.id.uuidString
        }
        var matchedIDs: [UUID] = []
        var categoryID: UUID?
        var displayName: String?
        var makesCompact = false
        var appliedTagIDs: [PersistentIdentifier] = []
        var seenTags: Set<PersistentIdentifier> = []
        for rule in ordered {
            guard let captures = capturesIfMatched(
                rule, amountMinorUnits: amountMinorUnits, description: description
            ) else { continue }
            matchedIDs.append(rule.id)
            if categoryID == nil { categoryID = rule.categoryID }
            if displayName == nil, let template = rule.displayNameTemplate {
                displayName = render(template: template, captures: captures)
            }
            makesCompact = makesCompact || rule.makesCompact
            for tagID in rule.appliedTagIDs where seenTags.insert(tagID).inserted {
                appliedTagIDs.append(tagID)
            }
        }
        return RuleEffects(
            matchingRuleIDs: matchedIDs,
            categoryID: categoryID,
            displayName: displayName,
            makesCompact: makesCompact,
            appliedTagIDs: appliedTagIDs
        )
    }

    /// Whether one rule's condition matches a transaction. Exposed so the rule
    /// editor can preview a draft without duplicating the matching logic.
    public static func matches(_ rule: RuleSnapshot, amountMinorUnits: Int64, description: String) -> Bool {
        capturesIfMatched(rule, amountMinorUnits: amountMinorUnits, description: description) != nil
    }

    private static func capturesIfMatched(
        _ rule: RuleSnapshot,
        amountMinorUnits: Int64,
        description: String
    ) -> [String]? {
        if let min = rule.minAmountMinorUnits, amountMinorUnits < min { return nil }
        if let max = rule.maxAmountMinorUnits, amountMinorUnits > max { return nil }

        switch rule.field {
        case .amount:
            // Amount rules with no explicit bounds would match everything; treat
            // the pattern as an exact amount when present at the rule's precision.
            if rule.pattern.isEmpty { return [] }
            guard let target = MinorUnits.parse(rule.pattern, exponent: 2) else { return nil }
            return amountMinorUnits == target ? [] : nil
        case .payee:
            return matchesText(rule, description: description)
        }
    }

    /// How long one regular-expression rule may take before it is abandoned.
    ///
    /// Deliberately generous. The job is to tell "microseconds" from
    /// "unbounded" — a merchant pattern matches in microseconds, and a pattern
    /// that backtracks exponentially takes minutes — so the budget only has to be
    /// longer than a scheduling artefact. A tighter one would disable a perfectly
    /// good rule on a busy device, which is a worse failure than a two-second
    /// pause in a background pass, and the pause happens at most once per pattern.
    static let regexBudget: DispatchTimeInterval = .seconds(2)

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

    private static func matchesText(_ rule: RuleSnapshot, description: String) -> [String]? {
        let pattern = rule.pattern
        guard !pattern.isEmpty else { return nil }

        switch rule.matchKind {
        case .contains:
            return description.range(of: pattern, options: .caseInsensitive) != nil ? [] : nil
        case .beginsWith:
            return description.range(of: pattern, options: [.caseInsensitive, .anchored]) != nil ? [] : nil
        case .endsWith:
            return description.lowercased().hasSuffix(pattern.lowercased()) ? [] : nil
        case .equals:
            return description.compare(pattern, options: .caseInsensitive) == .orderedSame ? [] : nil
        case .regularExpression:
            return regexCaptures(pattern, description: description, budget: regexBudget)
        }
    }

    private static func render(template: String, captures: [String]) -> String? {
        if captures.isEmpty {
            let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let token = try? NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        guard let token else { return nil }
        var output = ""
        var position = template.startIndex
        for match in token.matches(in: template, range: range) {
            guard let full = Range(match.range, in: template),
                  let numberRange = Range(match.range(at: 1), in: template),
                  let index = Int(template[numberRange]) else { continue }
            output += template[position..<full.lowerBound]
            output += captures.indices.contains(index) ? captures[index] : String(template[full])
            position = full.upperBound
        }
        output += template[position...]
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
    ///
    /// The budget is a parameter so a test can prove the deadline fires without
    /// waiting seconds for a real overrun.
    static func matchesRegex(
        _ pattern: String,
        description: String,
        budget: DispatchTimeInterval = regexBudget
    ) -> Bool {
        regexCaptures(pattern, description: description, budget: budget) != nil
    }

    private static func regexCaptures(
        _ pattern: String,
        description: String,
        budget: DispatchTimeInterval
    ) -> [String]? {
        guard let regex = RegexCache.shared.regex(for: pattern) else { return nil }
        let pending = PendingRegexMatch(
            regex: regex,
            text: description,
            range: NSRange(description.startIndex..<description.endIndex, in: description)
        )
        RegexCache.shared.queue.async { pending.run() }
        guard let result = pending.result(within: budget) else {
            RegexCache.shared.disable(pattern)
            return nil
        }
        guard let result else { return nil }
        return (0..<result.numberOfRanges).map { index in
            guard let range = Range(result.range(at: index), in: description) else { return "" }
            return String(description[range])
        }
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
    private var match: NSTextCheckingResult?

    init(regex: NSRegularExpression, text: String, range: NSRange) {
        self.regex = regex
        self.text = text
        self.range = range
    }

    func run() {
        match = regex.firstMatch(in: text, range: range)
        finished.signal()
    }

    /// The result, or `nil` when the budget runs out first. The semaphore orders
    /// the write in `run()` before this read, so no lock is needed.
    func result(within budget: DispatchTimeInterval) -> NSTextCheckingResult?? {
        guard finished.wait(timeout: .now() + budget) == .success else { return nil }
        return .some(match)
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
