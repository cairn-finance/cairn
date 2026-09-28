import Foundation
import Testing
@testable import CairnCore

@Suite("Cash-flow forecasting")
struct CashFlowForecastTests {
    private let day = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC

    @Test("Applies signed commitments without mixing currencies")
    func appliesCommitments() {
        let due = Calendar(identifier: .gregorian).date(byAdding: .day, value: 2, to: day)!
        let item = ConfirmedCommitmentValue(amountMinorUnits: -2_500, nextDueDate: due)
        let points = CashFlowForecast.balances(accounts: [ForecastAccount(balanceMinorUnits: 10_000, currency: .usd, asOf: day)], commitments: [item], through: 3, now: day)
        #expect(points.count == 4)
        #expect(points[1].balanceMinorUnits == 10_000)
        #expect(points[2].balanceMinorUnits == 7_500)
    }

    @Test("Missing or old balances mark the scenario uncertain")
    func staleIsUncertain() {
        let points = CashFlowForecast.balances(accounts: [ForecastAccount(balanceMinorUnits: 1_000, currency: .usd)], commitments: [], through: 1, now: day)
        #expect(points.allSatisfy { point in point.uncertainty })
    }

    @Test("Commitment status distinguishes paid, changed, due, and missed")
    func statuses() {
        let calendar = Calendar(identifier: .gregorian)
        let due = calendar.date(byAdding: .day, value: 2, to: day)!
        #expect(CommitmentStatusEvaluator.status(nextDueDate: due, now: day) == .upcoming)
        #expect(CommitmentStatusEvaluator.status(nextDueDate: day, now: day) == .due)
        #expect(CommitmentStatusEvaluator.status(nextDueDate: day, now: calendar.date(byAdding: .day, value: 1, to: day)!) == .missed)
        #expect(CommitmentStatusEvaluator.status(nextDueDate: due, now: day, lastObservedDate: due, expectedAmount: 10, observedAmount: 10) == .paid)
        #expect(CommitmentStatusEvaluator.status(nextDueDate: due, now: day, expectedAmount: 10, observedAmount: 12) == .changed)
        #expect(CommitmentStatusEvaluator.status(nextDueDate: due, now: day, uncertain: true) == .uncertain)
    }
}
