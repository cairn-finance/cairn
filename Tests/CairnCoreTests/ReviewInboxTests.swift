import Foundation
import Testing
@testable import CairnCore

@Suite("Review Inbox")
struct ReviewInboxTests {
    @Test("Uncategorized and new rows explain why they need review")
    func reasonsForNewUncategorizedRow() {
        let item = ReviewInboxItem(row: row(categoryName: nil, reviewedAt: nil))

        #expect(item?.reasons == [.uncategorized, .notReviewed])
        #expect(item?.primaryReason == .uncategorized)
    }

    @Test("A changed row is included after it was reviewed")
    func changedAfterReview() {
        let reviewed = Date(timeIntervalSince1970: 100)
        let item = ReviewInboxItem(
            row: row(
                categoryName: "Food",
                reviewedAt: reviewed,
                modifiedAt: Date(timeIntervalSince1970: 101)
            )
        )

        #expect(item?.reasons == [.changedSinceReview])
    }

    @Test("Reviewed, categorized rows stay out and ignored rows never appear")
    func completedRowsStayOut() {
        let date = Date(timeIntervalSince1970: 100)
        #expect(ReviewInboxItem(row: row(categoryName: "Food", reviewedAt: date, modifiedAt: date)) == nil)
        #expect(ReviewInboxItem(row: row(categoryName: nil, reviewedAt: nil, isIgnored: true)) == nil)
    }

    private func row(
        categoryName: String?,
        reviewedAt: Date?,
        modifiedAt: Date = Date(timeIntervalSince1970: 100),
        isIgnored: Bool = false
    ) -> TransactionRowValue {
        TransactionRowValue(
            id: UUID().uuidString,
            persistentID: nil,
            payeeDescription: "Coffee",
            amountMinorUnits: -500,
            currency: .usd,
            effectiveDate: Date(timeIntervalSince1970: 1),
            isPending: false,
            isIgnored: isIgnored,
            isTransfer: false,
            reviewedAt: reviewedAt,
            modifiedAt: modifiedAt,
            countsAsTransfer: false,
            categoryName: categoryName,
            categorySymbolName: categoryName == nil ? nil : "fork.knife",
            categoryColorHex: nil,
            accountName: "Checking",
            tagNames: []
        )
    }
}
