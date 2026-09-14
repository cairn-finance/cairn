import Foundation

/// One user-confirmed merchant-to-category association, used to learn from
/// corrections. Built from transactions the person has categorized themselves.
public struct MemorySample: Sendable, Hashable {
    public let merchantKey: String
    public let categoryID: UUID

    public init(merchantKey: String, categoryID: UUID) {
        self.merchantKey = merchantKey
        self.categoryID = categoryID
    }

    /// Convenience that normalizes a raw merchant name into a grouping key.
    public init(merchant: String, categoryID: UUID) {
        self.init(merchantKey: memoryKey(for: merchant), categoryID: categoryID)
    }
}

/// A stable, punctuation-insensitive key for merchant grouping and lookup.
private func memoryKey(for merchant: String) -> String {
    let withoutApostrophes = merchant
        .replacingOccurrences(of: "'", with: "")
        .replacingOccurrences(of: "\u{2019}", with: "")
    return TextSimilarity.normalize(MerchantNormalizer.normalize(withoutApostrophes))
}

/// On-device memory of how the person has categorized merchants before.
///
/// This is intentionally not a trained model: it is a majority vote over prior
/// corrections, so it is explainable, instant, works on every device, and never
/// leaves the device. It improves automatically as the person categorizes.
public struct MerchantMemory: Sendable {
    /// Majority category per normalized merchant key.
    public let exact: [String: UUID]
    /// Share of samples supporting the majority category, in `0...1`.
    public let confidence: [String: Double]
    public let samples: [MemorySample]

    public init(samples: [MemorySample]) {
        self.samples = samples

        var tallies: [String: [UUID: Int]] = [:]
        for sample in samples {
            tallies[memoryKey(for: sample.merchantKey), default: [:]][sample.categoryID, default: 0] += 1
        }

        var exact: [String: UUID] = [:]
        var confidence: [String: Double] = [:]
        for (key, tally) in tallies {
            let total = tally.values.reduce(0, +)
            guard let best = tally.max(by: { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key.uuidString < rhs.key.uuidString
            }) else { continue }
            exact[key] = best.key
            confidence[key] = total > 0 ? Double(best.value) / Double(total) : 0
        }

        self.exact = exact
        self.confidence = confidence
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// The remembered category for a merchant, if any.
    public func category(forMerchant merchant: String) -> (categoryID: UUID, confidence: Double)? {
        let key = memoryKey(for: merchant)
        guard let categoryID = exact[key] else { return nil }
        return (categoryID, confidence[key] ?? 0.5)
    }

    /// Falls back to the nearest remembered merchant by string similarity, for
    /// variants the normalizer didn't collapse (e.g. "Trader Joes Market" vs
    /// "Trader Joe's"). Returns nil below `threshold`.
    public func categoryBySimilarity(
        forMerchant merchant: String,
        threshold: Double = 0.82
    ) -> (categoryID: UUID, score: Double)? {
        let key = memoryKey(for: merchant)
        guard !key.isEmpty else { return nil }

        var best: (categoryID: UUID, score: Double)?
        for sample in samples {
            let score = Self.similarity(key, memoryKey(for: sample.merchantKey))
            guard score >= threshold else { continue }
            if score > (best?.score ?? 0) {
                best = (sample.categoryID, score)
            }
        }
        return best
    }

    /// Token-aware similarity. When one merchant's tokens are a subset of the
    /// other's ("trader joes" ⊂ "trader joes market") that is a strong signal
    /// even though the edit distance would be poor.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }

        let lhsTokens = Set(lhs.split(separator: " ").map(String.init))
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init))
        let intersection = lhsTokens.intersection(rhsTokens).count
        guard intersection > 0 else { return TextSimilarity.ratio(lhs, rhs) }

        let union = lhsTokens.union(rhsTokens).count
        let jaccard = Double(intersection) / Double(union)
        let smaller = min(lhsTokens.count, rhsTokens.count)
        let containment = smaller > 0 ? Double(intersection) / Double(smaller) : 0
        return max(jaccard, containment * 0.95)
    }
}

/// How a suggested category was produced.
public enum SuggestionSource: String, Sendable, Codable, CaseIterable {
    case rule
    case memory
    case similarMerchant
    case appleIntelligence

    public var displayName: String {
        switch self {
        case .rule: "Rule"
        case .memory: "Your history"
        case .similarMerchant: "Similar merchant"
        case .appleIntelligence: "Apple Intelligence"
        }
    }
}

public struct CategorySuggestion: Sendable, Hashable {
    public let categoryID: UUID
    public let source: SuggestionSource
    public let confidence: Double

    public init(categoryID: UUID, source: SuggestionSource, confidence: Double) {
        self.categoryID = categoryID
        self.source = source
        self.confidence = confidence
    }
}

/// Deterministic, on-device categorization. Layers run cheapest-first and stop
/// at the first confident answer:
///
/// 1. Rules the person (or the app) wrote.
/// 2. Merchant memory learned from their own corrections.
/// 3. Fuzzy match against remembered merchants.
///
/// Apple Intelligence is a separate, optional layer (see
/// `AppleIntelligenceCategorizer`) that runs only when asked.
public enum CategorySuggester {
    public static func suggest(
        description: String,
        merchant: String,
        amountMinorUnits: Int64,
        rules: [RuleSnapshot],
        memory: MerchantMemory
    ) -> CategorySuggestion? {
        if let categoryID = RulesEngine.categoryID(
            amountMinorUnits: amountMinorUnits,
            description: description,
            rules: rules
        ) {
            return CategorySuggestion(categoryID: categoryID, source: .rule, confidence: 1)
        }

        if let match = memory.category(forMerchant: merchant.isEmpty ? description : merchant) {
            return CategorySuggestion(categoryID: match.categoryID, source: .memory, confidence: match.confidence)
        }

        if let match = memory.categoryBySimilarity(forMerchant: merchant.isEmpty ? description : merchant) {
            return CategorySuggestion(
                categoryID: match.categoryID,
                source: .similarMerchant,
                confidence: match.score * 0.8
            )
        }

        return nil
    }
}
