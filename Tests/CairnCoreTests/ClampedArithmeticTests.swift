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

    @Test("A holding whose numbers overflow still reports a gain")
    func holdingGainDoesNotTrap() {
        let holding = Holding(holdingID: "H1", name: "Fund", currency: .usd)
        holding.hasCostBasis = true
        holding.marketValueMinorUnits = .max
        holding.costBasisMinorUnits = .min
        #expect(holding.gain?.minorUnits == .max)
    }
}
