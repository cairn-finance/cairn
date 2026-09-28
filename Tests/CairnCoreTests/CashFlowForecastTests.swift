import Foundation
import Testing
@testable import CairnCore

@Suite("Cash-flow forecasting")
struct CashFlowForecastTests {
    private let day = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC

    @Test("Applies signed commitments without mixing currencies")
    func appliesCommitments() throws {
        let due = try #require(
            Calendar(identifier: .gregorian).date(byAdding: .day, value: 2, to: day)
        )
        let item = ConfirmedCommitmentValue(amountMinorUnits: -2_500, nextDueDate: due)
        let points = CashFlowForecast.balances(
            accounts: [ForecastAccount(balanceMinorUnits: 10_000, currency: .usd, asOf: day)],
            commitments: [item],
            through: 3,
            now: day
        )
        #expect(points.count == 4)
        #expect(points[1].balanceMinorUnits == 10_000)
        #expect(points[2].balanceMinorUnits == 7_500)
    }

    @Test("Applies a commitment due today and repeats on calendar months")
    func dueTodayAndCalendarRecurrence() throws {
        let calendar = Calendar(identifier: .gregorian)
        let due = try #require(calendar.date(from: DateComponents(year: 2025, month: 1, day: 31)))
        let item = ConfirmedCommitmentValue(
            amountMinorUnits: -1_000,
            cadence: .monthly,
            nextDueDate: due
        )
        let points = CashFlowForecast.balances(
            accounts: [ForecastAccount(balanceMinorUnits: 10_000, currency: .usd, asOf: due)],
            commitments: [item],
            through: 31,
            now: due,
            calendar: calendar
        )

        #expect(points.first?.balanceMinorUnits == 9_000)
        #expect(points[27].balanceMinorUnits == 9_000)
        #expect(points[28].balanceMinorUnits == 8_000) // February 28, not March 2.
    }

    @Test("Does not combine currencies with the same code")
    func distinguishesCurrencyDescriptors() {
        let first = Currency(code: "PTS", exponent: 0, isCustom: true, customName: "Points")
        let second = Currency(code: "PTS", exponent: 2, isCustom: true, customName: "Points")
        let points = CashFlowForecast.balances(
            accounts: [
                ForecastAccount(balanceMinorUnits: 100, currency: first, asOf: day),
                ForecastAccount(balanceMinorUnits: 2_000, currency: second, asOf: day),
            ],
            commitments: [],
            through: 0,
            now: day
        )

        #expect(points.count == 2)
        #expect(Set(points.map(\.balanceMinorUnits)) == [100, 2_000])
    }

    @Test("Missing or old balances mark the scenario uncertain")
    func staleIsUncertain() {
        let points = CashFlowForecast.balances(
            accounts: [ForecastAccount(balanceMinorUnits: 1_000, currency: .usd)],
            commitments: [],
            through: 1,
            now: day
        )
        #expect(points.allSatisfy { point in point.uncertainty })
    }

    @Test("Commitment status distinguishes paid, changed, due, and missed")
    func statuses() throws {
        let calendar = Calendar(identifier: .gregorian)
        let due = try #require(calendar.date(byAdding: .day, value: 2, to: day))
        #expect(CommitmentStatusEvaluator.status(nextDueDate: due, now: day) == .upcoming)
        #expect(CommitmentStatusEvaluator.status(nextDueDate: day, now: day) == .due)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        #expect(CommitmentStatusEvaluator.status(nextDueDate: day, now: tomorrow) == .missed)
        #expect(
            CommitmentStatusEvaluator.status(
                nextDueDate: due,
                now: day,
                lastObservedDate: due,
                expectedAmount: 10,
                observedAmount: 10
            ) == .paid
        )
        #expect(CommitmentStatusEvaluator.status(nextDueDate: due, now: day, expectedAmount: 10, observedAmount: 12) == .changed)
        #expect(CommitmentStatusEvaluator.status(nextDueDate: due, now: day, uncertain: true) == .uncertain)
    }
}
