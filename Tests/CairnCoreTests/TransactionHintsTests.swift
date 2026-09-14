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
}
