import Foundation
import SwiftData

/// Identifies one account whose transactions Insights should read. A value so
/// the main actor can hand it to the background fetcher without passing models.
public struct InsightAccountScope: Sendable, Hashable {
    public let bankAccountID: String
    public let displayName: String

    public init(bankAccountID: String, displayName: String) {
        self.bankAccountID = bankAccountID
        self.displayName = displayName
    }
}

/// Builds ``InsightTransaction`` snapshots off the main actor.
///
/// Insights used to assemble its input by walking every account's `transactions`
/// relationship on the main actor, which faulted the whole store while the
/// screen was drawing. This actor fetches and maps on its own executor, then
/// returns `Sendable` values the main actor can use directly.
///
/// Create it from a non-main context (for example inside a detached task): the
/// generated `@ModelActor` initializer binds its executor to the calling
/// thread, so constructing it on the main actor would leave the work there.
@ModelActor
public actor InsightsFetcher {
    /// Rows at or after `earliest`, mapped to calculator input. Older rows
    /// cannot affect a snapshot, so they are dropped before a value is built.
    public func insightTransactions(
        scopes: [InsightAccountScope],
        earliest: Date
    ) -> [InsightTransaction] {
        var result: [InsightTransaction] = []
        for scope in scopes {
            let bankAccountID = scope.bankAccountID
            let descriptor = FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.accountIDIndex == bankAccountID }
            )
            guard let rows = try? modelContext.fetch(descriptor) else { continue }
            for transaction in rows where transaction.effectiveDate >= earliest {
                let category = transaction.effectiveCategory
                result.append(
                    InsightTransaction(
                        date: transaction.effectiveDate,
                        amountMinorUnits: transaction.amountMinorUnits,
                        categoryName: category?.name,
                        categoryColorHex: category?.colorHex,
                        categorySymbolName: category?.symbolName,
                        merchant: transaction.normalizedMerchant.isEmpty
                            ? transaction.payeeDescription
                            : transaction.normalizedMerchant,
                        accountName: scope.displayName,
                        isTransfer: transaction.countsAsTransfer,
                        isIgnored: transaction.isIgnored,
                        isPending: transaction.isPending
                    )
                )
            }
        }
        return result
    }
}
