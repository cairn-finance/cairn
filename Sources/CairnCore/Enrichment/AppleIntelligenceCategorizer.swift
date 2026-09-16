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

/// Local-only categorization using Apple's on-device foundation model.
///
/// Cairn deliberately uses `SystemLanguageModel`, the on-device model. It never
/// uses the Private Cloud Compute model (`PrivateCloudComputeLanguageModel`)
/// available from iOS 27, so transaction text never leaves the device. Every
/// call is gated on `SystemLanguageModel.default.isAvailable`.
public enum AppleIntelligenceCategorizer {
    /// Always true: Cairn only ever uses the on-device model.
    public static let usesLocalModelOnly = true
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

    /// Asks the on-device model to choose one of the provided category names.
    /// Returns nil when unavailable, or when the model's answer isn't a close
    /// match to a real category.
    public static func classify(
        merchant: String,
        description: String,
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

            let session = LanguageModelSession {
                """
                You categorize personal-finance transactions. Choose exactly one
                category from the list the user provides. Prefer the most specific
                category that fits the merchant.

                Rules:
                - Categorize by what was bought, not by words like "overdraft",
                  "pending", or "authorization" that only describe the process.
                - Never choose a fee category unless the description explicitly
                  names a charge (for example "fee" or "service charge").
                - Money moving between the person's own accounts, credit-card
                  payments, and payments to other people are not spending.
                - Always choose the closest category from the list.
                """
            }

            let prompt = """
            Categories: \(categories.joined(separator: ", "))
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
