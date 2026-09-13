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

    static func matches(_ rule: RuleSnapshot, amountMinorUnits: Int64, description: String) -> Bool {
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
            return (try? Regex(pattern)) != nil
                ? description.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
                : false
        }
    }
}
