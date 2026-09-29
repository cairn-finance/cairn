import Foundation
import SwiftData

/// Schema version 5 adds named budget schedules for one-time expenses.
///
/// The transaction itself remains an unchanged version-4 model. Schedule
/// records link to it through encrypted account and transaction identifiers,
/// so bank-owned ledger fields and balances remain untouched.
public enum CairnSchemaV5: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        CairnSchemaV4.models + [BudgetSmoothingPlan.self]
    }

    @Model
    public final class BudgetSmoothingPlan {
        public var uuid: UUID = UUID()
        @Attribute(.allowsCloudEncryption) public var accountIDIndex: String = ""
        @Attribute(.allowsCloudEncryption) public var bankTransactionID: String = ""
        @Attribute(.allowsCloudEncryption) public var name: String = ""
        @Attribute(.allowsCloudEncryption) public var startMonthKey: String = "1970-01"
        @Attribute(.allowsCloudEncryption) public var durationMonths: Int = 12
        public var createdAt: Date = Date.now
        public var modifiedAt: Date = Date.now

        public init(
            accountIDIndex: String = "",
            bankTransactionID: String = "",
            name: String = "",
            startMonthKey: String = "1970-01",
            durationMonths: Int = 12,
            now: Date = .now
        ) {
            self.accountIDIndex = accountIDIndex
            self.bankTransactionID = bankTransactionID
            self.name = name
            self.startMonthKey = startMonthKey
            self.durationMonths = durationMonths
            self.createdAt = now
            self.modifiedAt = now
        }
    }
}

public typealias BudgetSmoothingPlan = CairnSchemaV5.BudgetSmoothingPlan
