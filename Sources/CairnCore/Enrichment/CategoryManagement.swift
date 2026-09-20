import Foundation

/// What should happen when someone asks to remove a category.
public enum CategoryDeletionDecision: Sendable, Equatable {
    /// Nothing points at it, so it can be truly deleted.
    case delete
    /// Transactions or rules still point at it, so hide it instead.
    case archive
    /// Built-in categories are structural and can never be removed.
    case forbidden
}

/// The small, deterministic rules behind category management. Kept free of
/// SwiftData so the policy can be reasoned about and tested on its own; the
/// `SyncEngine` applies it to the store.
public enum CategoryManagement {
    /// Names whose behavior Cairn keys on by name. These are promised to exist
    /// and must never be renamed, archived, or removed, and no custom category
    /// may take their name: transfer pairing, fee/income routing, recategorize,
    /// the model-batch exclusions, and invalid-model clearing all match on them.
    public static let systemCategoryNames: Set<String> = [
        "Transfers", "Uncategorized", "Credit Card Payments", "Loan Payments", "Fees", "Income",
    ]

    /// A category name that is safe to persist: trimmed, and non-empty. Returns
    /// `nil` when the name is blank.
    public static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether a name belongs to one of the built-in categories, ignoring case.
    public static func isSystemCategoryName(_ name: String) -> Bool {
        systemCategoryNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether two category names collide, ignoring case and surrounding space.
    public static func namesCollide(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// How a removal request should be handled. A category that transactions or
    /// rules still reference is archived rather than deleted, so those records
    /// keep a readable label. System categories are never removed.
    public static func deletionDecision(
        isSystem: Bool,
        transactionCount: Int,
        ruleCount: Int
    ) -> CategoryDeletionDecision {
        if isSystem { return .forbidden }
        if transactionCount > 0 || ruleCount > 0 { return .archive }
        return .delete
    }
}
