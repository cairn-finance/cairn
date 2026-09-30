import Testing
@testable import CairnCore

struct InvestmentPortfolioSummaryTests {
    @Test("Position totals stay currency-separated and identify partial basis coverage")
    func summarizesByCurrency() {
        let usdWithBasis = holding(
            id: "usd-1", symbol: "AAA", currency: .usd,
            value: 15_000, basis: 10_000
        )
        let usdWithoutBasis = holding(
            id: "usd-2", symbol: "BBB", currency: .usd,
            value: 8_000
        )
        let eurHolding = holding(
            id: "eur-1", symbol: "CCC", currency: Currency(code: "EUR"),
            value: 20_000, basis: 22_000
        )

        let summaries = InvestmentPortfolioSummary.byCurrency(
            holdings: [usdWithBasis, usdWithoutBasis, eurHolding]
        )

        let usd = summaries.first { $0.currency == .usd }
        #expect(usd?.positionValueMinorUnits == 23_000)
        #expect(usd?.costBasisMinorUnits == 10_000)
        #expect(usd?.unrealizedGainMinorUnits == 5_000)
        #expect(usd?.positionCount == 2)
        #expect(usd?.costBasisPositionCount == 1)
        #expect(usd?.missingCostBasisPositionCount == 1)
        #expect(usd?.hasPartialCostBasis == true)
        #expect(usd?.hasCompleteCostBasis == false)

        let eur = summaries.first { $0.currency.code == "EUR" }
        #expect(eur?.positionValueMinorUnits == 20_000)
        #expect(eur?.costBasisMinorUnits == 22_000)
        #expect(eur?.unrealizedGainMinorUnits == -2_000)
        #expect(eur?.hasCompleteCostBasis == true)
        #expect(summaries.count == 2)
    }

    @Test("Position mix combines tickers and groups smaller positions as Other")
    func groupsPositionMix() {
        let holdings = [
            holding(id: "a1", symbol: "AAA", currency: .usd, value: 12_000),
            holding(id: "a2", symbol: "aaa", currency: .usd, value: 3_000),
            holding(id: "b", symbol: "BBB", currency: .usd, value: 9_000),
            holding(id: "c", symbol: "CCC", currency: .usd, value: 6_000),
            holding(id: "d", symbol: "DDD", currency: .usd, value: 3_000),
            holding(id: "e", symbol: "EEE", currency: .usd, value: 2_000),
            holding(id: "f", symbol: "FFF", currency: .usd, value: 1_000),
            holding(id: "negative", symbol: "NEG", currency: .usd, value: -500),
            holding(id: "eur", symbol: "EUR", currency: Currency(code: "EUR"), value: 99_000),
        ]

        let mix = InvestmentPortfolioSummary.positionMix(holdings: holdings, currency: .usd, limit: 3)

        #expect(mix.map(\.label) == ["AAA", "BBB", "CCC", "Other"])
        #expect(mix.map(\.valueMinorUnits) == [15_000, 9_000, 6_000, 6_000])
        #expect(mix.last?.isOther == true)
        #expect(mix.allSatisfy { $0.valueMinorUnits > 0 })
    }

    private func holding(
        id: String,
        symbol: String,
        currency: Currency,
        value: Int64,
        basis: Int64? = nil
    ) -> Holding {
        let holding = Holding(holdingID: id, name: symbol, currency: currency)
        holding.symbol = symbol
        holding.marketValueMinorUnits = value
        if let basis {
            holding.hasCostBasis = true
            holding.costBasisMinorUnits = basis
        }
        return holding
    }
}
