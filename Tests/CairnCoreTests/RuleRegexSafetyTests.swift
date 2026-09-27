import Dispatch
import Foundation
import Testing
@testable import CairnCore

/// A regex rule that takes an unreasonable amount of time must not be able to
/// stall a pass over thousands of transactions, and the shapes that cause it
/// should be recognisable before a rule is even saved.
@Suite("Rule regex safety")
struct RuleRegexSafetyTests {
    private func payeeRule(_ pattern: String) -> RuleSnapshot {
        RuleSnapshot(
            id: UUID(),
            field: .payee,
            matchKind: .regularExpression,
            pattern: pattern,
            categoryID: UUID()
        )
    }

    @Test("Obvious exponential shapes are refused")
    func nestedQuantifiersAreUnsafe() {
        #expect(!RulesEngine.isSafePattern("(a+)+"))
        #expect(!RulesEngine.isSafePattern("([0-9]*)*"))
        #expect(!RulesEngine.isSafePattern("^(x+)*$"))
        #expect(!RulesEngine.isSafePattern("((ab+))+"))
        #expect(!RulesEngine.isSafePattern("(a{2,})+"))
    }

    @Test("Ordinary patterns are accepted")
    func ordinaryPatternsAreSafe() {
        #expect(RulesEngine.isSafePattern("^ATM"))
        #expect(RulesEngine.isSafePattern("^(AMAZON|AMZN) "))
        #expect(RulesEngine.isSafePattern("COFFEE$"))
        #expect(RulesEngine.isSafePattern("[0-9]{4,6}"))
        #expect(RulesEngine.isSafePattern("(ab)+c"))
        #expect(RulesEngine.isSafePattern("\\+1 \\(555\\)"))
        #expect(RulesEngine.isSafePattern("GROCERY [0-9]+"))
        // A quantifier inside a character class is a literal, not a repeat.
        #expect(RulesEngine.isSafePattern("([a+])+"))
    }

    @Test("A pattern longer than a merchant name is refused")
    func longPatternsAreRefused() {
        #expect(!RulesEngine.isSafePattern(String(repeating: "a", count: 201)))
        #expect(RulesEngine.isSafePattern(String(repeating: "a", count: 200)))
    }

    @Test("An overrun is abandoned, and the pattern is never evaluated twice")
    func overrunIsAbandonedAndDisabled() {
        // Hold a serial evaluation queue briefly instead of running a genuinely
        // catastrophic regex. That exercises the deadline deterministically and
        // cannot leave a CPU-heavy regex competing with the rest of the suite.
        let pattern = "^SAFE"
        let queue = DispatchQueue(label: "com.sehej.cairn.tests.rules.regex")
        queue.async { Thread.sleep(forTimeInterval: 0.05) }

        let started = Date()
        let matched = RulesEngine.matchesRegex(
            pattern, description: "SAFE MERCHANT", budget: .milliseconds(1), queue: queue
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(!matched)
        #expect(elapsed < 1, "a pattern over its budget must not hold the caller")
        #expect(RulesEngine.disabledPatterns.contains(pattern))

        // Disabled means skipped: the next transaction pays nothing for it.
        let second = Date()
        _ = RulesEngine.matchesRegex(
            pattern, description: "SAFE MERCHANT", budget: .milliseconds(1), queue: queue
        )
        #expect(Date().timeIntervalSince(second) < 0.05)
    }

    @Test("A normal regex rule still matches")
    func normalRuleMatches() {
        let rule = payeeRule("^WHOLE FOODS")
        #expect(RulesEngine.matches(rule, amountMinorUnits: -1_234, description: "WHOLE FOODS #123"))
        #expect(!RulesEngine.matches(rule, amountMinorUnits: -1_234, description: "TRADER JOES"))
    }
}
