import Foundation

/// Position value and reported cost-basis coverage for one currency.
public struct InvestmentCurrencySummary: Identifiable, Hashable, Sendable {
    public var id: String { currency.stableIdentifier }

    public let currency: Currency
    public let positionValueMinorUnits: Int64
    public let costBasisMinorUnits: Int64?
    public let unrealizedGainMinorUnits: Int64?
    public let positionCount: Int
    public let costBasisPositionCount: Int

    public var hasPartialCostBasis: Bool {
        costBasisPositionCount > 0 && costBasisPositionCount < positionCount
    }

    public var hasCompleteCostBasis: Bool {
        positionCount > 0 && costBasisPositionCount == positionCount
    }

    public var missingCostBasisPositionCount: Int {
        positionCount - costBasisPositionCount
    }
}

/// One named slice of a portfolio value mix. Repeated tickers are combined.
public struct InvestmentPositionMix: Identifiable, Hashable, Sendable {
    public var id: String { key }

    public let key: String
    public let label: String
    public let valueMinorUnits: Int64
    public let isOther: Bool
}

/// Currency-safe calculations for reported investment positions.
public enum InvestmentPortfolioSummary {
    /// Summarizes reported position values and only the cost basis the bank
    /// actually supplied. No totals are combined across currencies.
    public static func byCurrency(holdings: [Holding]) -> [InvestmentCurrencySummary] {
        Dictionary(grouping: holdings, by: \.currency)
            .map { currency, positions in
                let basisPositions = positions.filter(\.hasCostBasis)
                let costBasis = basisPositions.reduce(Int64(0)) {
                    MinorUnits.addClamped($0, $1.costBasisMinorUnits)
                }
                let gain = basisPositions.reduce(Int64(0)) {
                    MinorUnits.addClamped($0, $1.gain?.minorUnits ?? 0)
                }

                return InvestmentCurrencySummary(
                    currency: currency,
                    positionValueMinorUnits: positions.reduce(Int64(0)) {
                        MinorUnits.addClamped($0, $1.marketValueMinorUnits)
                    },
                    costBasisMinorUnits: basisPositions.isEmpty ? nil : costBasis,
                    unrealizedGainMinorUnits: basisPositions.isEmpty ? nil : gain,
                    positionCount: positions.count,
                    costBasisPositionCount: basisPositions.count
                )
            }
            .sorted { $0.currency.stableIdentifier < $1.currency.stableIdentifier }
    }

    /// Builds a readable position mix for one currency, combining repeated
    /// tickers and grouping positions below the top `limit` into “Other”.
    /// Non-positive values are omitted because they cannot form pie slices.
    public static func positionMix(
        holdings: [Holding],
        currency: Currency,
        limit: Int = 5
    ) -> [InvestmentPositionMix] {
        let grouped = Dictionary(grouping: holdings.filter {
            $0.currency == currency && $0.marketValueMinorUnits > 0
        }, by: positionKey)

        let positions = grouped.map { key, holdings in
            (
                key: key,
                label: holdings.first?.displayLabel ?? "Holding",
                value: holdings.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.marketValueMinorUnits) }
            )
        }
        .sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            let labelOrder = $0.label.localizedStandardCompare($1.label)
            if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
            return $0.key < $1.key
        }

        let namedCount = max(0, limit)
        let named = positions.prefix(namedCount).map {
            InvestmentPositionMix(key: $0.key, label: $0.label, valueMinorUnits: $0.value, isOther: false)
        }
        let remainder = positions.dropFirst(namedCount)
        guard !remainder.isEmpty else { return named }

        let otherValue = remainder.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.value) }
        return named + [InvestmentPositionMix(
            key: "other",
            label: "Other",
            valueMinorUnits: otherValue,
            isOther: true
        )]
    }

    private static func positionKey(_ holding: Holding) -> String {
        if let symbol = holding.symbol?.trimmingCharacters(in: .whitespacesAndNewlines), !symbol.isEmpty {
            return "symbol:\(symbol.uppercased())"
        }

        let name = holding.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return "name:\(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
        }
        return "holding:\(holding.holdingID)"
    }
}
