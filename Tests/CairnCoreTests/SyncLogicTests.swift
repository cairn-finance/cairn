import Foundation
import Testing
@testable import CairnCore

@Suite("Pending to posted matching")
struct TransactionMatchingTests {
    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(Double(offset) * 86_400)
    }

    private func pending(
        id: String = "P1",
        amount: Int64,
        description: String,
        at offset: Int
    ) -> PendingTransactionCandidate {
        PendingTransactionCandidate(
            id: id,
            accountID: "A1",
            amountMinorUnits: amount,
            description: description,
            transactedAt: day(offset)
        )
    }

    private func posted(
        id: String,
        amount: Int64,
        description: String,
        at offset: Int
    ) -> PostedTransactionCandidate {
        PostedTransactionCandidate(
            id: id,
            accountID: "A1",
            amountMinorUnits: amount,
            description: description,
            postedDate: day(offset)
        )
    }

    @Test("Promotes a pending charge that posts under a new id")
    func promotesAcrossIDs() {
        let match = TransactionMatching.findMatch(
            for: pending(amount: -1_234, description: "STARBUCKS #1234 SEATTLE", at: 0),
            among: [posted(id: "S1", amount: -1_234, description: "STARBUCKS 1234", at: 1)]
        )
        #expect(match == "S1")
    }

    @Test("Ignores candidates with a different amount")
    func rejectsDifferentAmount() {
        let match = TransactionMatching.findMatch(
            for: pending(amount: -1_234, description: "STARBUCKS", at: 0),
            among: [posted(id: "S1", amount: -9_999, description: "STARBUCKS", at: 1)]
        )
        #expect(match == nil)
    }

    @Test("Ignores candidates outside the date window")
    func rejectsOutsideWindow() {
        let match = TransactionMatching.findMatch(
            for: pending(amount: -1_234, description: "STARBUCKS", at: 0),
            among: [posted(id: "S1", amount: -1_234, description: "STARBUCKS", at: 30)]
        )
        #expect(match == nil)
    }

    @Test("Ignores candidates from a different account")
    func rejectsDifferentAccount() {
        let other = PostedTransactionCandidate(
            id: "S1",
            accountID: "A2",
            amountMinorUnits: -1_234,
            description: "STARBUCKS",
            postedDate: day(1)
        )
        #expect(TransactionMatching.findMatch(
            for: pending(amount: -1_234, description: "STARBUCKS", at: 0),
            among: [other]
        ) == nil)
    }

    @Test("Picks the best description match when several amounts tie")
    func picksBest() {
        let match = TransactionMatching.findMatch(
            for: pending(amount: -2_500, description: "Whole Foods Market 123", at: 0),
            among: [
                posted(id: "WRONG", amount: -2_500, description: "Somewhere Else", at: 1),
                posted(id: "RIGHT", amount: -2_500, description: "WHOLE FOODS MARKET", at: 1),
            ]
        )
        #expect(match == "RIGHT")
    }
}

@Suite("Text similarity")
struct TextSimilarityTests {
    @Test("Identical text scores 1")
    func identical() {
        #expect(TextSimilarity.ratio("Coffee Shop", "coffee shop") == 1)
    }

    @Test("Unrelated text scores low")
    func unrelated() {
        #expect(TextSimilarity.ratio("Coffee", "Gas Station") < 0.4)
    }

    @Test("Normalization removes punctuation")
    func normalization() {
        #expect(TextSimilarity.normalize("Uncle Frank's  Bait-Shop!") == "uncle frank s bait shop")
    }
}

@Suite("Sync request window")
struct SyncRequestWindowTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func days(_ value: Int) -> Date {
        Self.calendar.date(byAdding: .day, value: value, to: now) ?? now
    }

    @Test("First sync backfills just under the 90-day limit")
    func firstSync() {
        let start = SyncEngine.requestStartDate(lastSyncDate: nil, now: now, calendar: Self.calendar)
        #expect(abs(start.timeIntervalSince(days(-SyncEngine.initialBackfillDays))) < 1)
        #expect(start >= days(-90))
    }

    @Test("Incremental sync re-requests a short overlap")
    func incremental() {
        let start = SyncEngine.requestStartDate(lastSyncDate: days(-1), now: now, calendar: Self.calendar)
        #expect(abs(start.timeIntervalSince(days(-(1 + SyncEngine.syncOverlapDays)))) < 1)
    }

    @Test("A long gap is clamped to the 90-day limit")
    func clampedAfterGap() {
        let start = SyncEngine.requestStartDate(lastSyncDate: days(-365), now: now, calendar: Self.calendar)
        #expect(abs(start.timeIntervalSince(days(-SyncEngine.maximumRequestDays))) < 1)
        #expect(now.timeIntervalSince(start) <= 90 * 86_400)
    }
}

@Suite("Balance history")
struct BalanceHistoryTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Reconstructs a past balance from current balance")
    func reconstructs() {
        let today = base
        let entries = [
            BalanceHistory.Entry(date: base.addingTimeInterval(86_400), amountMinorUnits: 500),
            BalanceHistory.Entry(date: base.addingTimeInterval(-86_400), amountMinorUnits: -2_000),
        ]
        // Balance today = current - everything posted after today.
        #expect(BalanceHistory.balance(asOf: today, currentBalanceMinorUnits: 10_000, transactions: entries) == 9_500)
        // Going back before yesterday adds both the negative and positive back.
        #expect(BalanceHistory.balance(asOf: base.addingTimeInterval(-2 * 86_400), currentBalanceMinorUnits: 10_000, transactions: entries) == 11_500)
    }

    @Test("Daily series is inclusive and ordered ascending")
    func dailySeries() throws {
        let end = base
        let start = base.addingTimeInterval(-3 * 86_400)
        let series = BalanceHistory.dailyBalances(
            from: start,
            through: end,
            currentBalanceMinorUnits: 1_000,
            transactions: []
        )
        #expect(series.count == 4)
        let first = try #require(series.first)
        let last = try #require(series.last)
        #expect(first.date <= last.date)
        #expect(series.allSatisfy { $0.balanceMinorUnits == 1_000 })
    }
}
