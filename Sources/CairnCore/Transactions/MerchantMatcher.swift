import Foundation

/// Conservative fuzzy matching for merchant names from different institutions.
public enum MerchantMatcher {
    private static let similarityThreshold = 0.84
    private static let minimumNameLength = 8

    /// Returns whether two normalized merchant names are likely the same
    /// merchant. Short or unrelated names stay separate rather than being
    /// merged on a weak edit-distance match.
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = MerchantNormalizer.groupingKey(lhs)
        let right = MerchantNormalizer.groupingKey(rhs)
        guard left != right else { return true }

        let leftText = TextSimilarity.normalize(left)
        let rightText = TextSimilarity.normalize(right)
        guard leftText.count >= minimumNameLength,
              rightText.count >= minimumNameLength else { return false }

        let leftTokens = Set(leftText.split(separator: " "))
        let rightTokens = Set(rightText.split(separator: " "))
        let sharedTokens = leftTokens.intersection(rightTokens).count
        let tokenOverlap = Double(sharedTokens) / Double(max(leftTokens.count, rightTokens.count))
        guard tokenOverlap >= 0.5 else { return false }

        return TextSimilarity.ratio(leftText, rightText) >= similarityThreshold
    }
}
