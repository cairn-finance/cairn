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

    @Test("Paying a bill is spending, not a transfer")
    func billPaymentsAreSpending() {
        // "autopay", "bill pay" and "epayment" describe how a bill was paid,
        // not money moving between the person's own accounts. Treating them as
        // transfers hid utility and insurance bills from spending.
        for description in [
            "AUTOPAY CITY UTILITIES",
            "BILL PAY ACME INSURANCE",
            "EPAYMENT CITY WATER",
            "AUTOMATIC PAYMENT - VERIZON WIRELESS",
            "BILLPAY - STATE FARM",
        ] {
            #expect(!TransactionHints.isInternalTransfer(description: description), "\(description)")
            #expect(TransactionHints.moneyMovement(description: description) == nil, "\(description)")
        }

        // A card payment is still money movement, because a card is named.
        #expect(TransactionHints.moneyMovement(description: "CREDIT CARD AUTOPAY PAYMENT") == .creditCardPayment)
        #expect(TransactionHints.moneyMovement(description: "CHASE CREDIT CRD AUTOPAY") == .creditCardPayment)
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

    @Test("An account named Chase doesn't match a card purchase")
    func ownAccountNamesUseWordBoundaries() {
        // SimpleFIN usually names the connection just "Chase", so a Chase
        // customer would otherwise see every "PURCHASE AUTHORIZED ON…" row
        // become a transfer.
        let counterparties = ["Chase", "Everyday Checking", "SoFi"]
        for description in [
            "PURCHASE AUTHORIZED ON 09/12 CARD 1234",
            "POS PURCHASE 4471",
            "PURCHASING DEPARTMENT",
        ] {
            #expect(
                !TransactionHints.isTransferToInstitution(
                    description: description,
                    counterparties: counterparties
                ),
                "\(description) must not be money movement"
            )
        }

        // A real transfer to that same account still matches.
        for description in ["CHASE CREDIT CRD AUTOPAY", "Transfer to Everyday Checking", "ACH: SOFI"] {
            #expect(
                TransactionHints.isTransferToInstitution(
                    description: description,
                    counterparties: counterparties
                ),
                "\(description) should be money movement"
            )
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

    @Test("A card purchase is never mistaken for a transfer to a bank")
    func purchasesAreNotTransfersToChase() {
        // "chase" is a substring of "purchase", and "citi" of "citizen".
        // Institution names must only match on word boundaries.
        for description in [
            "PURCHASE AUTHORIZED ON 09/12 CARD 1234",
            "POS PURCHASE 4471",
            "PURCHASE",
            "CITIZEN ONE PAYMENT",
            "PURCHASING DEPARTMENT",
        ] {
            #expect(
                !TransactionHints.isTransferToInstitution(description: description),
                "\(description) must not be money movement"
            )
            #expect(
                !TransactionHints.isMoneyMovement(description: description),
                "\(description) must not be money movement"
            )
        }

        // The real institutions still match, with or without punctuation.
        for description in [
            "CHASE CREDIT CRD AUTOPAY",
            "JPMORGAN CHASE",
            "ACH: CHASE",
            "CHASE.COM",
            "CITIBANK CARD PAYMENT",
        ] {
            #expect(
                TransactionHints.isTransferToInstitution(description: description),
                "\(description) should be money movement"
            )
        }
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
