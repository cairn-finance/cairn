import Foundation
import Testing
@testable import CairnCore

@Suite("Non-trapping money arithmetic")
struct ClampedArithmeticTests {
    @Test("Sums clamp instead of trapping")
    func sumsClamp() {
        #expect(MinorUnits.addClamped(1_000, 2_000) == 3_000)
        #expect(MinorUnits.addClamped(.max, 1) == .max)
        #expect(MinorUnits.addClamped(.min, -1) == .min)
        #expect(MinorUnits.addClamped(.max, -1) == .max - 1)
    }

    @Test("Differences clamp instead of trapping")
    func differencesClamp() {
        #expect(MinorUnits.subtractClamped(2_000, 1_000) == 1_000)
        #expect(MinorUnits.subtractClamped(.min, 1) == .min)
        #expect(MinorUnits.subtractClamped(.max, -1) == .max)
    }

    @Test("Magnitudes clamp instead of trapping on Int64.min")
    func magnitudesClamp() {
        #expect(MinorUnits.absClamped(-5) == 5)
        #expect(MinorUnits.absClamped(5) == 5)
        #expect(MinorUnits.absClamped(.min) == .max)
    }

    @Test("Products clamp instead of trapping")
    func productsClamp() {
        #expect(MinorUnits.multiplyClamped(1_000, 3) == 3_000)
        #expect(MinorUnits.multiplyClamped(.max, 2) == .max)
        #expect(MinorUnits.multiplyClamped(.max, -2) == .min)
        #expect(MinorUnits.multiplyClamped(.min, 2) == .min)
        #expect(MinorUnits.multiplyClamped(4, 0) == 0)
    }

    @Test("Double conversions saturate instead of trapping")
    func doubleConversionsSaturate() {
        #expect(MinorUnits.clampedFromDouble(1_234.4) == 1_234)
        #expect(MinorUnits.clampedFromDouble(1_234.6) == 1_235)
        #expect(MinorUnits.clampedFromDouble(1e30) == .max)
        #expect(MinorUnits.clampedFromDouble(-1e30) == .min)
        #expect(MinorUnits.clampedFromDouble(.infinity) == .max)
        #expect(MinorUnits.clampedFromDouble(-.infinity) == .min)
        // A rate divided by a vanishing denominator is the realistic way to
        // produce a NaN; it must not reach `Int64(_:)`.
        #expect(MinorUnits.clampedFromDouble(.nan) == 0)
    }

    @Test("A projected spend built from nonsense saturates instead of trapping")
    func projectedSpendDoesNotTrap() {
        func snapshot(
            spending: Int64,
            lastDayWithData: Int,
            averageDailyPace: Int64
        ) -> InsightsSnapshot {
            InsightsSnapshot(
                monthStart: .now,
                current: MonthlyTotals(monthStart: .now, incomeMinorUnits: 0, spendingMinorUnits: spending),
                previous: MonthlyTotals(monthStart: .now, incomeMinorUnits: 0, spendingMinorUnits: 0),
                categories: [],
                months: [],
                topMerchants: [],
                transactionCount: 0,
                cumulative: [PacePoint(day: lastDayWithData, amountMinorUnits: spending)],
                daysInMonth: 31,
                lastDayWithData: lastDayWithData,
                averageDailyPace: averageDailyPace,
                previousToDateSpending: 0,
                topMoverNames: []
            )
        }

        // The run-rate branch: one enormous day extrapolated over 31 days. The old
        // `Int64((rate * daysInMonth).rounded())` trapped here.
        #expect(snapshot(spending: .max, lastDayWithData: 5, averageDailyPace: 0).projectedSpending == .max)
        // The trailing-average branch: a plain unclamped multiply.
        #expect(snapshot(spending: .max, lastDayWithData: 1, averageDailyPace: .max).projectedSpending == .max)
        // A sane month is unaffected.
        #expect(snapshot(spending: 31_000, lastDayWithData: 31, averageDailyPace: 1_000).projectedSpending == 31_000)
    }

    @Test("A holding whose numbers overflow still reports a gain")
    func holdingGainDoesNotTrap() {
        let holding = Holding(holdingID: "H1", name: "Fund", currency: .usd)
        holding.hasCostBasis = true
        holding.marketValueMinorUnits = .max
        holding.costBasisMinorUnits = .min
        #expect(holding.gain?.minorUnits == .max)
    }
}
