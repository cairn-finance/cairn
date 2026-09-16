import Foundation

/// Pairs the two legs of a transfer that live in different accounts.
///
/// A transfer is often recognizable on only one side: the outgoing leg says
/// "Transfer" (or is a card or loan payment), while the matching credit in the
/// other account reads as a plain "Deposit" that the on-device model guessed as
/// Income. This pairs a recognized leg with its counterpart so the counterpart
/// can be marked as the same money movement instead of inflating income.
///
/// Deliberately conservative:
///
/// - the two legs must be in *different* accounts, so a brokerage dividend and
///   its reinvestment inside one account are left alone;
/// - the amounts must be exact opposites and the dates close together;
/// - only a *credit* counterpart is eligible, so a coincidental purchase is
///   never turned into a transfer;
/// - the counterpart must be uncategorized or carry only a weak Income guess,
///   never a category the person chose or a deterministic hint.
///
/// Pure and synchronous so the rules can be exhaustively unit-tested.
public enum TransferPairing {
    /// One transaction considered for pairing.
    public struct Leg<ID: Hashable & Sendable>: Sendable {
        public let id: ID
        public let accountID: String
        public let amountMinorUnits: Int64
        public let date: Date
        /// Recognized money movement on its own (a transfer, card, or loan
        /// payment). Only these anchor a pair.
        public let isAnchor: Bool
        /// May be reclassified as a transfer: a credit the person hasn't touched,
        /// with no category or only a weak one.
        public let isEligibleCounterpart: Bool

        public init(
            id: ID,
            accountID: String,
            amountMinorUnits: Int64,
            date: Date,
            isAnchor: Bool,
            isEligibleCounterpart: Bool
        ) {
            self.id = id
            self.accountID = accountID
            self.amountMinorUnits = amountMinorUnits
            self.date = date
            self.isAnchor = isAnchor
            self.isEligibleCounterpart = isEligibleCounterpart
        }
    }

    /// A bank transfer can post a few days after the money leaves the source
    /// account, so the window is generous enough for weekends and ACH settlement
    /// without stretching to unrelated look-alikes.
    public static let defaultWindowDays = 5

    /// Returns the ids of the counterpart legs that should be marked as transfers.
    ///
    /// Each leg is claimed at most once, so two anchors can't both claim the same
    /// counterpart. The largest amounts are paired first because they are the
    /// least likely to be a coincidence, and ties are broken by date and then by
    /// input order, making the result deterministic.
    public static func counterpartsToMark<ID: Hashable & Sendable>(
        in legs: [Leg<ID>],
        windowDays: Int = defaultWindowDays
    ) -> [ID] {
        guard legs.count > 1, windowDays >= 0 else { return [] }

        let anchors = legs.enumerated().filter {
            $0.element.isAnchor && $0.element.amountMinorUnits != 0
        }
        guard !anchors.isEmpty else { return [] }

        var counterpartsByAmount: [Int64: [Int]] = [:]
        for (index, leg) in legs.enumerated()
        where leg.isEligibleCounterpart && !leg.isAnchor && leg.amountMinorUnits > 0 {
            counterpartsByAmount[leg.amountMinorUnits, default: []].append(index)
        }
        guard !counterpartsByAmount.isEmpty else { return [] }

        let orderedAnchors = anchors.sorted { lhs, rhs in
            let lhsMagnitude = abs(lhs.element.amountMinorUnits)
            let rhsMagnitude = abs(rhs.element.amountMinorUnits)
            if lhsMagnitude != rhsMagnitude { return lhsMagnitude > rhsMagnitude }
            if lhs.element.date != rhs.element.date { return lhs.element.date < rhs.element.date }
            return lhs.offset < rhs.offset
        }

        // A little slack absorbs timezone and rounding drift around the boundary.
        let window = TimeInterval(windowDays) * 86_400 + 3_600
        var claimed = Set<Int>()
        var result: [ID] = []

        for anchor in orderedAnchors {
            let leg = anchor.element
            guard let candidates = counterpartsByAmount[-leg.amountMinorUnits] else { continue }

            var bestIndex: Int?
            var bestDistance = TimeInterval.greatestFiniteMagnitude
            for candidateIndex in candidates where !claimed.contains(candidateIndex) {
                let counterpart = legs[candidateIndex]
                guard counterpart.accountID != leg.accountID else { continue }
                let distance = abs(counterpart.date.timeIntervalSince(leg.date))
                guard distance <= window else { continue }
                if distance < bestDistance
                    || (distance == bestDistance && (bestIndex.map { candidateIndex < $0 } ?? true)) {
                    bestIndex = candidateIndex
                    bestDistance = distance
                }
            }

            if let bestIndex {
                claimed.insert(bestIndex)
                result.append(legs[bestIndex].id)
            }
        }

        return result
    }
}
