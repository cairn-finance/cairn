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
    /// A category name that is safe to persist: trimmed, and non-empty. Returns
    /// `nil` when the name is blank.
    public static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
