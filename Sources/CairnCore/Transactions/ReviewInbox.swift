import Foundation

/// The reason a transaction appears in Review Inbox. Kept as a value so the
/// inbox can explain itself without making the UI infer state from a model.
public enum ReviewReason: String, Sendable, Hashable, CaseIterable {
    case uncategorized
    case notReviewed
    case changedSinceReview

    public var title: String {
        switch self {
        case .uncategorized: "Needs a category"
        case .notReviewed: "Not reviewed yet"
        case .changedSinceReview: "Changed since review"
        }
    }

    public var systemImage: String {
        switch self {
        case .uncategorized: "questionmark.circle"
        case .notReviewed: "checkmark.circle"
        case .changedSinceReview: "arrow.triangle.2.circlepath"
        }
    }
}

/// A transaction plus the reasons it needs attention.
public struct ReviewInboxItem: Sendable, Hashable, Identifiable {
    public let row: TransactionRowValue
    public let reasons: [ReviewReason]

    public var id: String { row.id }
    public var primaryReason: ReviewReason { reasons[0] }

    public init?(row: TransactionRowValue) {
        guard !row.isIgnored else { return nil }
        var reasons: [ReviewReason] = []
        if row.needsCategory { reasons.append(.uncategorized) }
        if row.reviewedAt == nil {
            reasons.append(.notReviewed)
        } else if let reviewedAt = row.reviewedAt, row.modifiedAt > reviewedAt {
            reasons.append(.changedSinceReview)
        }
        guard !reasons.isEmpty else { return nil }
        self.row = row
        self.reasons = reasons
    }

    public static func items(from rows: [TransactionRowValue]) -> [ReviewInboxItem] {
        rows.compactMap(Self.init).sorted { $0.row.effectiveDate > $1.row.effectiveDate }
    }
}
