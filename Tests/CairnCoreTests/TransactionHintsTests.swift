import Foundation
import Testing
@testable import CairnCore

@Suite("Transaction hints")
struct TransactionHintsTests {
    @Test("Overdraft to checking is money movement, not a fee")
    func overdraftTransfer() {
        #expect(TransactionHints.isInternalTransfer(description: "Overdraft to checking"))
        #expect(!TransactionHints.isExplicitFee(description: "Overdraft to checking"))
        #expect(TransactionHints.isInternalTransfer(description: "Overdraft protection transfer"))
    }

    @Test("A charge has to be named a charge")
    func explicitFees() {
        #expect(TransactionHints.isExplicitFee(description: "Overdraft fee"))
        #expect(TransactionHints.isExplicitFee(description: "MONTHLY MAINTENANCE FEE"))
        #expect(TransactionHints.isExplicitFee(description: "NSF"))
        #expect(!TransactionHints.isInternalTransfer(description: "Overdraft fee"))
    }

    @Test("Coffee is never a fee")
    func coffeeIsNotAFee() {
        #expect(!TransactionHints.isExplicitFee(description: "Blue Bottle Coffee"))
        #expect(!TransactionHints.isExplicitFee(description: "Starbucks Coffee #123"))
    }

    @Test("Peer-to-peer payments are money movement")
    func peerToPeer() {
        #expect(TransactionHints.isInternalTransfer(description: "Zelle payment to Jordan"))
        #expect(TransactionHints.isInternalTransfer(description: "ZELLE PAYMENT FROM JANE DOE"))
        #expect(TransactionHints.isInternalTransfer(description: "Venmo payment"))
        #expect(TransactionHints.isInternalTransfer(description: "Cash App payment"))
    }

    @Test("Ordinary transfers and card payments")
    func internalTransfers() {
        #expect(TransactionHints.isInternalTransfer(description: "Transfer to Savings"))
        #expect(TransactionHints.isInternalTransfer(description: "Online transfer from checking"))
        #expect(TransactionHints.isInternalTransfer(description: "Payment - Thank You"))
        #expect(TransactionHints.isInternalTransfer(description: "Credit Card Payment"))
    }

    @Test("Plain purchases trip nothing")
    func plainPurchases() {
        for description in ["Whole Foods Market", "Shell Gas Station", "United Airlines"] {
            #expect(!TransactionHints.isInternalTransfer(description: description))
            #expect(!TransactionHints.isExplicitFee(description: description))
        }
    }

    @Test("A fee is always a debit")
    func feesMustBeDebits() {
        #expect(TransactionHints.isExplicitFee(description: "MONTHLY SERVICE FEE", amountMinorUnits: -1_500))
        // A credit that merely mentions a fee is a reversal or adjustment.
        #expect(!TransactionHints.isExplicitFee(description: "MONTHLY SERVICE FEE", amountMinorUnits: 1_500))
        #expect(!TransactionHints.isExplicitFee(description: "Overdraft fee", amountMinorUnits: 0))
    }

    @Test("Payroll and benefits are income")
    func payrollIsIncome() {
        #expect(TransactionHints.isIncome(
            description: "ACME INC PAYROLL PPD ID: 0000000000",
            amountMinorUnits: 200_000
        ))
        #expect(TransactionHints.isIncome(description: "ACH: BENEFIT PAYMENT", amountMinorUnits: 13_400))
        #expect(TransactionHints.isIncome(description: "Interest Payment", amountMinorUnits: 1_240))
        // Income only ever applies to money arriving.
        #expect(!TransactionHints.isIncome(description: "Payroll Deposit", amountMinorUnits: -100))
    }

    @Test("ACH rows that aren't pay stay out of income and fees")
    func achNonIncome() {
        for description in ["ACH: ACME SUPPLY", "ACH: CITY UTILITIES", "ACH: LOCAL MERCHANT"] {
            #expect(!TransactionHints.isExplicitFee(description: description, amountMinorUnits: -100_00))
            #expect(!TransactionHints.isIncome(description: description, amountMinorUnits: 200_000))
        }
    }

    @Test("Money to a financial institution is movement")
    func financialCounterpartiesAreTransfers() {
        for description in ["ACH: CAPITAL ONE", "ACH: AMERICAN EXPRESS", "ACH: CHASE", "ACH: VANGUARD"] {
            #expect(TransactionHints.isTransferToInstitution(description: description))
        }
        #expect(!TransactionHints.isTransferToInstitution(description: "ACH: ACME SUPPLY"))
        // A named charge is still a charge, never money movement.
        #expect(!TransactionHints.isTransferToInstitution(description: "MONTHLY SERVICE FEE"))
    }

    @Test("The person's own accounts match as counterparties")
    func ownAccountsAreTransfers() {
        let accounts = ["SoFi", "American Express", "Everyday Checking"]
        #expect(TransactionHints.isTransferToInstitution(description: "ACH: SOFI", counterparties: accounts))
        #expect(TransactionHints.isTransferToInstitution(
            description: "ACH: AMERICAN EXPRESS",
            counterparties: accounts
        ))
        // A full-name match must not fire on a shared first word.
        #expect(!TransactionHints.isTransferToInstitution(
            description: "AMERICAN AIRLINES",
            counterparties: accounts
        ))
        #expect(!TransactionHints.isTransferToInstitution(description: "Blue Bottle Coffee", counterparties: accounts))
    }
}
