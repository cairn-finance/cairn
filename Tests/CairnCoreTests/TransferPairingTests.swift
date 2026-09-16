import Foundation
import Testing
@testable import CairnCore

@Suite("Transfer pairing")
struct TransferPairingTests {
    private let day: TimeInterval = 86_400

    private func date(_ daysFromNow: Double) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + daysFromNow * 86_400)
    }

    /// A recognized transfer out of one account, and the credit it produced in
    /// another.
    private func legs(
        anchorAccount: String = "checking",
        counterpartAccount: String = "savings",
        anchorAmount: Int64 = -10_000,
        counterpartAmount: Int64 = 10_000,
        anchorDate: Date? = nil,
        counterpartDate: Date? = nil,
        counterpartEligible: Bool = true
    ) -> [TransferPairing.Leg<String>] {
        let anchorDay = anchorDate ?? date(0)
        let creditDay = counterpartDate ?? date(0)
        return [
            TransferPairing.Leg(
                id: "out",
                accountID: anchorAccount,
                amountMinorUnits: anchorAmount,
                date: anchorDay,
                isAnchor: true,
                isEligibleCounterpart: false
            ),
            TransferPairing.Leg(
                id: "in",
                accountID: counterpartAccount,
                amountMinorUnits: counterpartAmount,
                date: creditDay,
                isAnchor: false,
                isEligibleCounterpart: counterpartEligible
            ),
        ]
    }

    @Test("Pairs the credit leg of a transfer in another account")
    func pairsAcrossAccounts() {
        let marked = TransferPairing.counterpartsToMark(in: legs())
        #expect(marked == ["in"])
    }

    @Test("Never pairs two legs in the same account")
    func sameAccountDoesNotPair() {
        let marked = TransferPairing.counterpartsToMark(
            in: legs(counterpartAccount: "checking")
        )
        #expect(marked.isEmpty)
    }

    @Test("Amounts must be exact opposites")
    func mismatchedAmountsDoNotPair() {
        let marked = TransferPairing.counterpartsToMark(
            in: legs(counterpartAmount: 9_999)
        )
        #expect(marked.isEmpty)
    }

    @Test("A counterpart too far from the anchor is not paired")
    func windowIsRespected() {
        let inside = TransferPairing.counterpartsToMark(
            in: legs(counterpartDate: date(4))
        )
        #expect(inside == ["in"])

        let outside = TransferPairing.counterpartsToMark(
            in: legs(counterpartDate: date(30))
        )
        #expect(outside.isEmpty)
    }

    @Test("A counterpart the person touched is left alone")
    func ineligibleCounterpartIsSkipped() {
        let marked = TransferPairing.counterpartsToMark(
            in: legs(counterpartEligible: false)
        )
        #expect(marked.isEmpty)
    }

    @Test("A debit is never turned into a transfer")
    func debitCounterpartIsIgnored() {
        // The counterpart is a negative amount, i.e. an outgoing charge. Even
        // though it is the opposite of the anchor, pairing must not touch it.
        let pair = legs(anchorAmount: 10_000, counterpartAmount: -10_000)
        #expect(TransferPairing.counterpartsToMark(in: pair).isEmpty)
    }

    @Test("A counterpart is claimed by only one anchor")
    func counterpartIsClaimedOnce() {
        let pair: [TransferPairing.Leg<String>] = [
            TransferPairing.Leg(id: "outA", accountID: "checking", amountMinorUnits: -10_000,
                                date: date(0), isAnchor: true, isEligibleCounterpart: false),
            TransferPairing.Leg(id: "outB", accountID: "wallet", amountMinorUnits: -10_000,
                                date: date(0), isAnchor: true, isEligibleCounterpart: false),
            TransferPairing.Leg(id: "in", accountID: "savings", amountMinorUnits: 10_000,
                                date: date(0), isAnchor: false, isEligibleCounterpart: true),
        ]
        let marked = TransferPairing.counterpartsToMark(in: pair)
        #expect(marked == ["in"])
    }

    @Test("The closest counterpart in time wins")
    func nearestDateWins() {
        let pair: [TransferPairing.Leg<String>] = [
            TransferPairing.Leg(id: "out", accountID: "checking", amountMinorUnits: -10_000,
                                date: date(0), isAnchor: true, isEligibleCounterpart: false),
            TransferPairing.Leg(id: "far", accountID: "savingsA", amountMinorUnits: 10_000,
                                date: date(3), isAnchor: false, isEligibleCounterpart: true),
            TransferPairing.Leg(id: "near", accountID: "savingsB", amountMinorUnits: 10_000,
                                date: date(1), isAnchor: false, isEligibleCounterpart: true),
        ]
        #expect(TransferPairing.counterpartsToMark(in: pair) == ["near"])
    }

    @Test("A zero amount never pairs")
    func zeroAmountIsIgnored() {
        let pair: [TransferPairing.Leg<String>] = [
            TransferPairing.Leg(id: "out", accountID: "checking", amountMinorUnits: 0,
                                date: date(0), isAnchor: true, isEligibleCounterpart: false),
            TransferPairing.Leg(id: "in", accountID: "savings", amountMinorUnits: 0,
                                date: date(0), isAnchor: false, isEligibleCounterpart: true),
        ]
        #expect(TransferPairing.counterpartsToMark(in: pair).isEmpty)
    }

    @Test("A paired credit cannot anchor a further pair")
    func pairingDoesNotCascade() {
        // The savings credit is only a counterpart; it must not become an anchor
        // that pulls an unrelated charge in a third account into a transfer.
        let pair: [TransferPairing.Leg<String>] = [
            TransferPairing.Leg(id: "out", accountID: "checking", amountMinorUnits: -10_000,
                                date: date(0), isAnchor: true, isEligibleCounterpart: false),
            TransferPairing.Leg(id: "in", accountID: "savings", amountMinorUnits: 10_000,
                                date: date(0), isAnchor: false, isEligibleCounterpart: true),
            TransferPairing.Leg(id: "third", accountID: "wallet", amountMinorUnits: -10_000,
                                date: date(0), isAnchor: false, isEligibleCounterpart: true),
        ]
        #expect(TransferPairing.counterpartsToMark(in: pair) == ["in"])
    }
}
