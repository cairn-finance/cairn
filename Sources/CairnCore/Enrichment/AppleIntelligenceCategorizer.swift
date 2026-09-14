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

/// Optional zero-shot categorization using Apple's on-device foundation model
/// (Apple Intelligence). This never sends data anywhere: the model runs on the
/// device. It is used only as a last resort when rules and learned history have
/// no answer, and every call is gated on availability.
public enum AppleIntelligenceCategorizer {
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
            let session = LanguageModelSession {
                """
                You categorize personal-finance transactions. Choose exactly one
                category from the list the user provides. Prefer the most specific
                category. Respond with the category name only.
                """
            }

            let prompt = """
            Categories: \(categories.joined(separator: ", "))
            Transaction merchant: \(merchant.isEmpty ? "unknown" : merchant)
            Transaction description: \(description)
            Which single category fits best?
            """

            let response = try await session.respond(to: prompt, generating: InferredCategory.self)
            return CategoryNameMatcher.match(response.content.category, to: categories)
        }
        #endif

        return nil
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct InferredCategory {
        @Guide(description: "The single best-matching category name from the provided list.")
        var category: String
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
