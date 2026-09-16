import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Maps a free-form category name produced by a model back onto one of the
/// person's actual category names. Pure and unit-testable.
public enum CategoryNameMatcher {
    public static func match(_ candidate: String, to categories: [String], threshold: Double = 0.7) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let exact = categories.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact
        }

        var best: (name: String, score: Double)?
        for category in categories {
            let score = TextSimilarity.ratio(trimmed, category)
            if best == nil || score > best!.score {
                best = (category, score)
            }
        }
        if let best, best.score >= threshold { return best.name }
        return nil
    }
}

/// A snapshot of what the on-device model offers on this device.
///
/// The base on-device model is the same ~3B parameter Apple Foundation Model on
/// every Apple Intelligence device, but it is not identical everywhere: newer,
/// more capable Apple silicon can run a larger sparse on-device variant, Apple
/// swaps the model in OS updates, and the context window is a fixed 4096 tokens
/// per session. Cairn reads the capabilities the OS reports and sizes its work
/// from them, rather than assuming one device's model.
public struct DeviceProfile: Sendable, Equatable {
    public let isAvailable: Bool
    public let unavailableReason: String?
    /// Maximum tokens a single session can hold, straight from the OS.
    public let contextSize: Int
    public let supportedLanguageCount: Int
    /// How many merchants to ask about in one model call, derived from the
    /// context window so a small model is never overfilled.
    public let recommendedBatchSize: Int

    public init(
        isAvailable: Bool,
        unavailableReason: String?,
        contextSize: Int,
        supportedLanguageCount: Int,
        recommendedBatchSize: Int
    ) {
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
        self.contextSize = contextSize
        self.supportedLanguageCount = supportedLanguageCount
        self.recommendedBatchSize = recommendedBatchSize
    }

    /// A short, non-identifying description for Settings and diagnostics.
    public var summary: String {
        guard isAvailable else { return unavailableReason ?? "Unavailable" }
        let window = contextSize > 0 ? "\(contextSize)-token window" : "context size unknown"
        return "On-device model ready · \(window) · up to \(recommendedBatchSize) merchants per call"
    }
}

/// One merchant to classify in a batched model call. `id` is opaque to the
/// model and used only to map the answer back to the caller's group.
public struct MerchantQuery: Sendable, Equatable, Hashable {
    public let id: Int
    public let merchant: String
    public let isCredit: Bool

    public init(id: Int, merchant: String, isCredit: Bool) {
        self.id = id
        self.merchant = merchant
        self.isCredit = isCredit
    }
}

/// Local-only categorization using Apple's on-device foundation model.
///
/// Cairn deliberately uses `SystemLanguageModel`, the on-device model. It never
/// uses the Private Cloud Compute model (`PrivateCloudComputeLanguageModel`)
/// available from iOS 27, so transaction text never leaves the device. Every
/// call is gated on `SystemLanguageModel.default.isAvailable`.
///
/// Cairn could also use the `contentTagging` use case, but that model emits
/// free-form semantic tags ("grocery shopping"), not one of the person's actual
/// category names. Matching those back to real categories would need a keyword
/// table, which Cairn avoids. The general model with a runtime-constrained
/// schema is the only approach that guarantees every answer is a real category.
public enum AppleIntelligenceCategorizer {
    /// Always true: Cairn only ever uses the on-device model.
    public static let usesLocalModelOnly = true

    /// Longest merchant description sent to the model. Transaction descriptions
    /// can be very long and every token counts against a 4096-token window.
    private static let maxMerchantCharacters = 90

    public enum Availability: Sendable, Equatable {
        case available
        case unavailable(String)
    }

    public static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(reasonDescription(reason))
            @unknown default:
                return .unavailable("Apple Intelligence is unavailable right now.")
            }
        }
        #endif
        return .unavailable("Apple Intelligence requires a supported device.")
    }

    public static var isAvailable: Bool { availability == .available }

    public static var statusDescription: String {
        switch availability {
        case .available: "Apple Intelligence is available on this device."
        case .unavailable(let reason): reason
        }
    }

    /// The model's context window on this device, or 0 when unknown/unavailable.
    /// Used both to size batches and to explain behavior in diagnostics.
    public static var contextSize: Int {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.contextSize
        }
        #endif
        return 0
    }

    /// How many merchants fit comfortably in one model call on this device.
    ///
    /// The on-device context window is fixed (4096 tokens for the base model),
    /// shared by instructions, the category list, the merchants, and the
    /// generated answer. Budgeting ~60 tokens per merchant leaves headroom for
    /// everything else. The result is clamped so a small model is never
    /// overfilled and a batch never grows so large that a single slow device
    /// spends a long time generating.
    public static var recommendedMerchantBatchSize: Int {
        let size = contextSize
        guard size > 0 else { return 8 }
        let budget = max(1, (size - 700) / 60)
        return max(4, min(12, budget))
    }

    public static var deviceProfile: DeviceProfile {
        let availability = availability
        let available: Bool
        let reason: String?
        switch availability {
        case .available: available = true; reason = nil
        case .unavailable(let text): available = false; reason = text
        }
        return DeviceProfile(
            isAvailable: available,
            unavailableReason: reason,
            contextSize: contextSize,
            supportedLanguageCount: supportedLanguageCount,
            recommendedBatchSize: recommendedMerchantBatchSize
        )
    }

    private static var supportedLanguageCount: Int {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.supportedLanguages.count
        }
        #endif
        return 0
    }

    /// Shared rules for every categorization prompt. Kept in one place so the
    /// single and batched paths can never drift apart.
    private static let categorizationRules = """
    You categorize personal-finance transactions. Choose exactly one category from
    the list the user provides. Prefer the most specific category that fits the
    merchant.

    Rules:
    - "Money in" means the amount is positive and the person received it. Choose
      Income for money in, unless it is a refund of a purchase or a transfer
      between the person's own accounts.
    - "Money out" means the amount is negative.
    - Categorize by what was bought, not by words like "overdraft", "pending", or
      "authorization" that only describe the process.
    - Never choose a fee category unless the description explicitly names a charge
      (for example "fee" or "service charge").
    - Money moving between the person's own accounts, credit-card payments, and
      payments to other people are not spending.
    - Always choose the closest category from the list.
    """

    /// Asks the on-device model to choose one of the provided category names.
    /// Returns nil when unavailable, or when the model's answer isn't a close
    /// match to a real category.
    public static func classify(
        merchant: String,
        description: String,
        isCredit: Bool,
        categories: [String]
    ) async throws -> String? {
        guard !categories.isEmpty else { return nil }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            // Constrain generation to the person's actual category names at
            // runtime. The model otherwise tends to answer with a more specific
            // name of its own invention ("Subscriptions", "Insurance"), which
            // matches nothing and leaves the transaction uncategorized. A schema
            // makes those names unrepresentable, so every answer is a real
            // category — without hardcoding any merchant-to-category table.
            guard let schema = categorySchema(for: categories) else { return nil }

            let session = LanguageModelSession { categorizationRules }

            let prompt = """
            Categories: \(categories.joined(separator: ", "))
            Direction: \(isCredit ? "money in" : "money out")
            Transaction merchant: \(merchant.isEmpty ? "unknown" : merchant)
            Transaction description: \(description)
            Which single category fits best?
            """

            let response = try await session.respond(to: prompt, schema: schema)
            let answer = try response.content.value(String.self)
            return CategoryNameMatcher.match(answer, to: categories)
        }
        #endif

        return nil
    }

    /// Classifies several merchants in a single model call, which is the main
    /// reason a large backlog is affordable: the per-call cost (loading and
    /// re-reading instructions) is paid once instead of per transaction, and a
    /// sync with thousands of rows usually has only a few hundred distinct
    /// merchants.
    ///
    /// Returns the validated category name for each query `id` that the model
    /// placed. Unplaced queries are simply absent, so the caller can re-ask them
    /// one at a time with the fully-constrained single-category schema.
    public static func classifyBatch(
        queries: [MerchantQuery],
        categories: [String]
    ) async throws -> [Int: String] {
        guard !queries.isEmpty, !categories.isEmpty else { return [:] }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let trimmed = queries.map {
                MerchantQuery(id: $0.id, merchant: trimmedMerchant($0.merchant), isCredit: $0.isCredit)
            }
            let session = LanguageModelSession {
                categorizationRules
                """
                You are given several merchants at once. Return exactly one
                assignment for each merchant, in the same order, using only the
                category names provided.
                """
            }

            let listing = trimmed.map { query in
                "\(query.id). \(query.merchant.isEmpty ? "unknown" : query.merchant) "
                    + "(\(query.isCredit ? "money in" : "money out"))"
            }.joined(separator: "\n")

            let prompt = """
            Categories: \(categories.joined(separator: ", "))
            Merchants:
            \(listing)
            Return one category for each merchant, in the same order.
            """

            let response = try await session.respond(to: prompt, generating: MerchantCategoryBatch.self)

            var result: [Int: String] = [:]
            for (index, assignment) in response.content.assignments.enumerated() {
                let id: Int?
                if let exact = trimmed.first(where: {
                    $0.merchant.caseInsensitiveCompare(assignment.merchant) == .orderedSame
                }) {
                    id = exact.id
                } else if index < trimmed.count {
                    id = trimmed[index].id
                } else {
                    id = nil
                }
                guard let id, result[id] == nil else { continue }
                if let match = CategoryNameMatcher.match(assignment.category, to: categories) {
                    result[id] = match
                }
            }
            return result
        }
        #endif

        return [:]
    }

    /// Collapses whitespace and bounds length so one verbose bank description
    /// can't crowd the rest of a batch out of the context window.
    static func trimmedMerchant(_ value: String) -> String {
        let collapsed = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxMerchantCharacters else { return trimmed }
        return String(trimmed.prefix(maxMerchantCharacters))
    }

    #if canImport(FoundationModels)
    /// A schema whose only possible value is one of `categories`, so the model
    /// can never answer with a name the person doesn't have.
    @available(iOS 26.0, macOS 26.0, *)
    private static func categorySchema(for categories: [String]) -> GenerationSchema? {
        try? GenerationSchema(
            root: DynamicGenerationSchema(
                name: "CategoryChoice",
                description: "The single best-matching category name from the provided list.",
                anyOf: categories
            ),
            dependencies: []
        )
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func reasonDescription(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            "This device doesn’t support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in Settings to use this."
        case .modelNotReady:
            "The on-device model is still downloading."
        @unknown default:
            "Apple Intelligence is unavailable right now."
        }
    }
    #endif
}

#if canImport(FoundationModels)
/// The batched answer. The category is left as free text and validated against
/// the person's real categories by `CategoryNameMatcher`; a merchant the model
/// can't place cleanly is re-asked with the hard-constrained single schema.
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct MerchantCategoryBatch {
    @Guide(description: "One assignment for every merchant listed, in the same order.")
    var assignments: [MerchantCategoryAssignment]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct MerchantCategoryAssignment {
    @Guide(description: "The merchant exactly as it was listed.")
    var merchant: String

    @Guide(description: "The single best category name from the provided list.")
    var category: String
}
#endif
