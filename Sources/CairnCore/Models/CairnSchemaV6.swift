import Foundation
import SwiftData

/// Personal tracking records are independent of bank accounts and the ledger.
/// Currency descriptors and split details are encrypted Codable payloads so
/// custom currencies retain their full identity without queryable copies.
public enum CairnSchemaV6: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        CairnSchemaV5.models + [SharedExpense.self, SharedExpensePayment.self, SinkingFund.self, SinkingFundEntry.self]
    }

    @Model
    public final class SharedExpense {
        public var uuid: UUID = UUID()
        @Attribute(.allowsCloudEncryption) public var title: String = ""
        @Attribute(.allowsCloudEncryption) public var date: Date = Date.now
        @Attribute(.allowsCloudEncryption) public var totalMinorUnits: Int64 = 0
        @Attribute(.allowsCloudEncryption) public var currencyData: Data = Data()
        @Attribute(.allowsCloudEncryption) public var participantsData: Data = Data()
        @Attribute(.allowsCloudEncryption) public var payerID: UUID = UUID()
        @Attribute(.allowsCloudEncryption) public var note: String = ""
        @Attribute(.allowsCloudEncryption) public var bankLinkData: Data?
        @Attribute(.allowsCloudEncryption) public var isArchived: Bool = false
        public var createdAt: Date = Date.now
        public var modifiedAt: Date = Date.now

        public init(uuid: UUID = UUID()) { self.uuid = uuid }
    }

    @Model
    public final class SharedExpensePayment {
        public var uuid: UUID = UUID()
        @Attribute(.allowsCloudEncryption) public var expenseID: UUID = UUID()
        @Attribute(.allowsCloudEncryption) public var participantID: UUID = UUID()
        @Attribute(.allowsCloudEncryption) public var amountMinorUnits: Int64 = 0
        @Attribute(.allowsCloudEncryption) public var date: Date = Date.now
        @Attribute(.allowsCloudEncryption) public var note: String = ""
        @Attribute(.allowsCloudEncryption) public var bankLinkData: Data?
        public var createdAt: Date = Date.now

        public init(uuid: UUID = UUID()) { self.uuid = uuid }
    }

    @Model
    public final class SinkingFund {
        public var uuid: UUID = UUID()
        @Attribute(.allowsCloudEncryption) public var name: String = ""
        @Attribute(.allowsCloudEncryption) public var currencyData: Data = Data()
        @Attribute(.allowsCloudEncryption) public var targetMinorUnits: Int64 = 0
        @Attribute(.allowsCloudEncryption) public var targetDate: Date?
        @Attribute(.allowsCloudEncryption) public var monthlyContributionMinorUnits: Int64 = 0
        @Attribute(.allowsCloudEncryption) public var timeZoneIdentifier: String = "UTC"
        @Attribute(.allowsCloudEncryption) public var stateRaw: String = "active"
        @Attribute(.allowsCloudEncryption) public var note: String = ""
        public var createdAt: Date = Date.now
        public var modifiedAt: Date = Date.now

        public init(uuid: UUID = UUID()) { self.uuid = uuid }
    }

    @Model
    public final class SinkingFundEntry {
        public var uuid: UUID = UUID()
        @Attribute(.allowsCloudEncryption) public var fundID: UUID = UUID()
        @Attribute(.allowsCloudEncryption) public var amountMinorUnits: Int64 = 0
        @Attribute(.allowsCloudEncryption) public var kindRaw: String = "contribution"
        @Attribute(.allowsCloudEncryption) public var date: Date = Date.now
        @Attribute(.allowsCloudEncryption) public var note: String = ""
        public var createdAt: Date = Date.now

        public init(uuid: UUID = UUID()) { self.uuid = uuid }
    }
}

public typealias SharedExpense = CairnSchemaV6.SharedExpense
public typealias SharedExpensePayment = CairnSchemaV6.SharedExpensePayment
public typealias SinkingFund = CairnSchemaV6.SinkingFund
public typealias SinkingFundEntry = CairnSchemaV6.SinkingFundEntry
