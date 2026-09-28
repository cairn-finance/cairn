import Testing
@testable import CairnCore

@Suite("Shared-expense settlements")
struct SettlementTests {
    @Test("Computes gross, received, net, and outstanding")
    func totals() {
        let summary = SettlementCalculator.summary(
            expenseAmountMinorUnits: -10_000,
            reimbursementAmountMinorUnits: 4_000,
            expectedAmountMinorUnits: 5_000,
            status: .partial
        )
        #expect(summary.grossExpenseMinorUnits == 10_000)
        #expect(summary.reimbursementReceivedMinorUnits == 4_000)
        #expect(summary.netPersonalCostMinorUnits == 6_000)
        #expect(summary.outstandingMinorUnits == 1_000)
        #expect(summary.status == .partial)
    }

    @Test("Requires an outgoing expense and incoming reimbursement")
    func validatesDirections() {
        #expect(throws: SettlementValidationError.expenseMustBeOutgoing) {
            try SettlementCalculator.validate(expenseAmountMinorUnits: 10, reimbursementAmountMinorUnits: 10)
        }
        #expect(throws: SettlementValidationError.reimbursementMustBeIncoming) {
            try SettlementCalculator.validate(expenseAmountMinorUnits: -10, reimbursementAmountMinorUnits: -10)
        }
        #expect(throws: SettlementValidationError.expectedAmountMustBePositive) {
            try SettlementCalculator.validate(expenseAmountMinorUnits: -10, reimbursementAmountMinorUnits: 10, expectedAmountMinorUnits: 0)
        }
    }

    @Test("Does not allow outstanding arithmetic to go negative")
    func overpayment() {
        let summary = SettlementCalculator.summary(
            expenseAmountMinorUnits: -100,
            reimbursementAmountMinorUnits: 200,
            status: .received
        )
        #expect(summary.netPersonalCostMinorUnits == 0)
        #expect(summary.outstandingMinorUnits == 0)
    }

    @Test("Rejects rows with matching currency codes but different currency descriptors")
    func currenciesMustMatchFully() {
        let expense = LedgerTransaction(amountMinorUnits: -1_000)
        let reimbursement = LedgerTransaction(amountMinorUnits: 1_000)
        expense.account = Account(currency: Currency(code: "PTS", exponent: 0, isCustom: true, customName: "Points", customAbbreviation: "P"))
        reimbursement.account = Account(currency: Currency(code: "PTS", exponent: 2, isCustom: true, customName: "Points", customAbbreviation: "P"))

        #expect(throws: SettlementValidationError.currenciesMustMatch) {
            try LedgerTransaction.linkSettlement(expense: expense, reimbursement: reimbursement, counterparty: nil, expectedAmountMinorUnits: nil)
        }
    }
}
