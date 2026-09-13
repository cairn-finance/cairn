import Foundation
import Testing
@testable import CairnCore

@Suite("Rules engine")
struct RulesEngineTests {
    private let groceries = UUID()
    private let dining = UUID()

    @Test("Matches a description substring")
    func containsMatch() {
        let rule = RuleSnapshot(
            id: UUID(), field: .payee, matchKind: .contains,
            pattern: "whole foods", categoryID: groceries
        )
        let result = RulesEngine.categoryID(
            amountMinorUnits: -5_000,
            description: "WHOLE FOODS MARKET #123",
            rules: [rule]
        )
        #expect(result == groceries)
    }

    @Test("Does not match when the pattern is absent")
    func noMatch() {
        let rule = RuleSnapshot(
            id: UUID(), field: .payee, matchKind: .contains,
            pattern: "whole foods", categoryID: groceries
        )
        #expect(RulesEngine.categoryID(
            amountMinorUnits: -5_000,
            description: "Shell Gas",
            rules: [rule]
        ) == nil)
    }

    @Test("Higher priority wins")
    func priority() {
        let low = RuleSnapshot(
            id: UUID(), field: .payee, matchKind: .contains,
            pattern: "coffee", categoryID: groceries, priority: 1
        )
        let high = RuleSnapshot(
            id: UUID(), field: .payee, matchKind: .contains,
            pattern: "coffee", categoryID: dining, priority: 10
        )
        #expect(RulesEngine.categoryID(
            amountMinorUnits: -500,
            description: "Blue Bottle Coffee",
            rules: [low, high]
        ) == dining)
    }

    @Test("Respects amount bounds")
    func amountBounds() {
        let rule = RuleSnapshot(
            id: UUID(), field: .payee, matchKind: .contains,
            pattern: "rent", minAmountMinorUnits: -300_000, maxAmountMinorUnits: -100_000,
            categoryID: groceries
        )
        #expect(RulesEngine.categoryID(
            amountMinorUnits: -195_000,
            description: "Rent Payment",
            rules: [rule]
        ) == groceries)
        #expect(RulesEngine.categoryID(
            amountMinorUnits: -50_000,
            description: "Rent Payment",
            rules: [rule]
        ) == nil)
    }

    @Test("Supports regular expressions")
    func regex() {
        let rule = RuleSnapshot(
            id: UUID(), field: .payee, matchKind: .regularExpression,
            pattern: "^AMZN[ ]?MKT", categoryID: dining
        )
        #expect(RulesEngine.categoryID(
            amountMinorUnits: -1_000,
            description: "AMZN MKT place",
            rules: [rule]
        ) == dining)
    }

    @Test("Begins-with anchors at the start")
    func beginsWith() {
        let rule = RuleSnapshot(
            id: UUID(), field: .payee, matchKind: .beginsWith,
            pattern: "payroll", categoryID: groceries
        )
        #expect(RulesEngine.categoryID(amountMinorUnits: 1, description: "Payroll Deposit", rules: [rule]) == groceries)
        #expect(RulesEngine.categoryID(amountMinorUnits: 1, description: "ACME Payroll", rules: [rule]) == nil)
    }
}

@Suite("Exporters")
struct ExportersTests {
    private func row(_ description: String, note: String? = nil) -> TransactionExportRow {
        TransactionExportRow(
            institution: "My Bank",
            account: "Checking",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            amount: "-12.34",
            currency: "USD",
            description: description,
            category: "Dining",
            note: note,
            transactionID: "T1"
        )
    }

    @Test("CSV has a header and one line per row")
    func csvShape() {
        let csv = Exporters.csv(rows: [row("Coffee, Shop")])
        let lines = csv.split(separator: "\r\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(lines[0].contains("Institution"))
    }

    @Test("CSV quotes fields containing commas and quotes")
    func csvEscaping() {
        #expect(Exporters.escapeCSV("a,b") == "\"a,b\"")
        #expect(Exporters.escapeCSV("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(Exporters.escapeCSV("plain") == "plain")
        #expect(Exporters.escapeCSV("line\nbreak") == "\"line\nbreak\"")
    }

    @Test("JSON export is valid and round-trips")
    func jsonRoundTrip() throws {
        let data = try Exporters.json(rows: [row("Coffee", note: "reimbursable")])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["format"] as? String == "cairn.transactions")
        let transactions = try #require(object?["transactions"] as? [[String: Any]])
        #expect(transactions.count == 1)
        #expect(transactions.first?["description"] as? String == "Coffee")
        #expect(transactions.first?["note"] as? String == "reimbursable")
    }

    @Test("CSV neutralizes formula injection in text, not amounts")
    func csvFormulaInjection() {
        #expect(Exporters.neutralizeFormulaInjection("=SUM(A1)") == "'=SUM(A1)")
        #expect(Exporters.neutralizeFormulaInjection("+1") == "'+1")
        #expect(Exporters.neutralizeFormulaInjection("-1") == "'-1")
        #expect(Exporters.neutralizeFormulaInjection("@cmd") == "'@cmd")
        #expect(Exporters.neutralizeFormulaInjection("Coffee") == "Coffee")
        #expect(Exporters.neutralizeFormulaInjection("") == "")

        let dangerous = TransactionExportRow(
            institution: "Bank",
            account: "Checking",
            date: Date(timeIntervalSince1970: 0),
            amount: "-12.34",
            currency: "USD",
            description: "=cmd()",
            note: "@evil",
            transactionID: "T1"
        )
        let csv = Exporters.csv(rows: [dangerous])
        #expect(csv.contains("'=cmd()"))
        #expect(csv.contains("'@evil"))
        // A negative amount must stay a number, not get an apostrophe.
        #expect(csv.contains(",-12.34,"))
        #expect(!csv.contains("'-12.34"))
    }
}
