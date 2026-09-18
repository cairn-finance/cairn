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
        // `(a+)+b` over a run of a's with no b is the textbook exponential case.
        // The run is kept short on purpose: once the caller gives up, that
        // abandoned evaluation has to finish on its own, and a long run would
        // leave a thread burning CPU for the rest of the suite.
        let pattern = "(a+)+b"
        let description = String(repeating: "a", count: 24)
        let rule = payeeRule(pattern)

        let started = Date()
        let matched = RulesEngine.matches(rule, amountMinorUnits: 0, description: description)
        let elapsed = Date().timeIntervalSince(started)

        #expect(!matched)
        #expect(elapsed < 2, "the caller must not wait for a pathological pattern")

        // The deadline is what is being tested. If ICU happened to answer this
        // one quickly there is nothing to abandon, and the rest is unobservable,
        // so the assertion is conditional rather than fragile.
        guard elapsed > 0.05 else { return }

        #expect(RulesEngine.disabledPatterns.contains(pattern))

        // Disabled means skipped: the next transaction pays nothing for it.
        let second = Date()
        _ = RulesEngine.matches(rule, amountMinorUnits: 0, description: description)
        #expect(Date().timeIntervalSince(second) < 0.05)
    }

    @Test("A normal regex rule still matches")
    func normalRuleMatches() {
        let rule = payeeRule("^WHOLE FOODS")
        #expect(RulesEngine.matches(rule, amountMinorUnits: -1_234, description: "WHOLE FOODS #123"))
        #expect(!RulesEngine.matches(rule, amountMinorUnits: -1_234, description: "TRADER JOES"))
    }
}
