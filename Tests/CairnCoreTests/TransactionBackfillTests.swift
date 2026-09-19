import Foundation
import SwiftData
import Testing
@testable import CairnCore

/// Walking older SimpleFIN transaction history back in 89-day windows.
@Suite("Transaction backfill")
@MainActor
struct TransactionBackfillTests {
    private func makeEngine() throws -> (container: ModelContainer, engine: SyncEngine) {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        return (result.container, SyncEngine(modelContainer: result.container))
    }

    private func accessURL() -> URL {
        URL(string: "https://demo:demo@example.com/simplefin")!
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(secondsFromGMT: 0) {
            calendar.timeZone = utc
        }
        return calendar
    }

    private func connection(_ id: String, org: String) -> SimpleFINConnection {
        SimpleFINConnection(id: id, name: id, organizationID: org)
    }

    private func posted(
        _ id: String,
        daysAgo: Int,
        now: Date,
        amount: Int64 = -100,
        description: String = "Coffee"
    ) -> SimpleFINTransaction {
        SimpleFINTransaction(
            id: id,
            postedDate: calendar().date(byAdding: .day, value: -daysAgo, to: now),
            transactedAt: nil,
            amountMinorUnits: amount,
            description: description,
            isPending: false
        )
    }

    private func accountSet(
        _ transactions: [SimpleFINTransaction],
        balance: Int64 = 1
    ) -> SimpleFINAccountSet {
        SimpleFINAccountSet(
            connections: [connection("CON-1", org: "ORG-1")],
            accounts: [
                SimpleFINAccount(
                    id: "1",
                    name: "Checking",
                    connectionID: "CON-1",
                    currency: .usd,
                    balanceMinorUnits: balance,
                    transactions: transactions
                )
            ],
            errors: []
        )
    }

    @discardableResult
    private func insertHolder(in context: ModelContext, credentialID: UUID) -> Institution {
        let holder = Institution(bankConnectionID: "", name: "Holder", credentialID: credentialID)
        context.insert(holder)
        return holder
    }

    @discardableResult
    private func insertConnection(
        in context: ModelContext,
        credentialID: UUID,
        connectionID: String,
        orgID: String
    ) -> Institution {
        let child = Institution(bankConnectionID: connectionID, name: connectionID, credentialID: credentialID)
        child.orgID = orgID
        context.insert(child)
        return child
    }

    @discardableResult
    private func insertAccount(
        in context: ModelContext,
        bankAccountID: String,
        institution: Institution,
        balance: Int64
    ) -> Account {
        let account = Account(bankAccountID: bankAccountID, name: bankAccountID, currency: .usd)
        account.balanceMinorUnits = balance
        account.institution = institution
        context.insert(account)
        return account
    }

    @discardableResult
    private func insertPosted(
        in context: ModelContext,
        id: String,
        daysAgo: Int,
        account: Account,
        now: Date
    ) -> LedgerTransaction {
        let row = LedgerTransaction(bankTransactionID: id, payeeDescription: "Coffee", amountMinorUnits: -100)
        row.postedDate = calendar().date(byAdding: .day, value: -daysAgo, to: now)
        row.accountIDIndex = account.bankAccountID
        row.account = account
        context.insert(row)
        return row
    }

    private func holder(in context: ModelContext) throws -> Institution {
        try #require(try context.fetch(FetchDescriptor<Institution>()).first { $0.isCredentialHolder })
    }

    @Test("Backfill walks back in windows and stops at the first empty one")
    func backfillWalksBack() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let credentialID = UUID()
        insertHolder(in: context, credentialID: credentialID)
        let child = insertConnection(in: context, credentialID: credentialID, connectionID: "CON-1", orgID: "ORG-1")
        let account = insertAccount(in: context, bankAccountID: "1", institution: child, balance: 500)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        insertPosted(in: context, id: "T-NEW", daysAgo: 10, account: account, now: now)
        try context.save()

        let stub = StubFetch { _, end in
            // Page one ends at the oldest stored row; page two is empty.
            if end > now.addingTimeInterval(-20 * 86_400) {
                return self.accountSet([self.posted("T-OLD", daysAgo: 40, now: now)])
            }
            return self.accountSet([])
        }

        let outcome = await engine.backfillHistory(
            institutionID: try holder(in: context).persistentModelID,
            accessURL: accessURL(),
            fetch: { url, start, end in try await stub.fetch(url, start, end) },
            maxPages: 5,
            now: now,
            calendar: calendar()
        )

        #expect(outcome.pagesFetched == 2)
        #expect(outcome.reachedFloor)
        #expect(!outcome.hitPageLimit)
        #expect(outcome.transactionsInserted == 1)
        #expect(try context.fetch(FetchDescriptor<LedgerTransaction>())
            .contains { $0.bankTransactionID == "T-OLD" })

        // Page one ends at the oldest stored row and reaches 89 days back.
        #expect(stub.calls.count == 2)
        #expect(abs(stub.calls[0].end.timeIntervalSince(now) + 10 * 86_400) < 1)
        #expect(abs(stub.calls[0].start.timeIntervalSince(now) + 99 * 86_400) < 1)
        // Page two picks up exactly where page one ended.
        #expect(abs(stub.calls[1].end.timeIntervalSince(stub.calls[0].start)) < 1)
    }

    @Test("Backfill never ages out a pending charge and never touches the balance")
    func backfillLeavesPendingAndBalanceAlone() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let credentialID = UUID()
        insertHolder(in: context, credentialID: credentialID)
        let child = insertConnection(in: context, credentialID: credentialID, connectionID: "CON-1", orgID: "ORG-1")
        let account = insertAccount(in: context, bankAccountID: "1", institution: child, balance: 777)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        insertPosted(in: context, id: "T-NEW", daysAgo: 10, account: account, now: now)

        // A live pending charge that the historical windows do not mention and
        // that a buggy promote would match on amount and description.
        let pending = LedgerTransaction(bankTransactionID: "P-1", payeeDescription: "Coffee", amountMinorUnits: -100)
        pending.isPending = true
        pending.accountIDIndex = "1"
        pending.account = account
        context.insert(pending)
        try context.save()

        let stub = StubFetch { _, end in
            // Two non-empty pages so a buggy age-out would reach its threshold.
            if end > now.addingTimeInterval(-30 * 86_400) {
                return self.accountSet([self.posted("T-OLD1", daysAgo: 40, now: now)], balance: 1)
            }
            if end > now.addingTimeInterval(-110 * 86_400) {
                return self.accountSet([self.posted("T-OLD2", daysAgo: 130, now: now)], balance: 1)
            }
            return self.accountSet([])
        }

        let outcome = await engine.backfillHistory(
            institutionID: try holder(in: context).persistentModelID,
            accessURL: accessURL(),
            fetch: { url, start, end in try await stub.fetch(url, start, end) },
            maxPages: 5,
            now: now,
            calendar: calendar()
        )
        #expect(outcome.pagesFetched == 3)
        #expect(outcome.reachedFloor)

        // The older rows were added, the balance was not overwritten, and the
        // pending charge survived without a mismatch count.
        let ids = Set(try context.fetch(FetchDescriptor<LedgerTransaction>()).map(\.bankTransactionID))
        #expect(ids.contains("T-OLD1"))
        #expect(ids.contains("T-OLD2"))
        let refreshed = try #require(try context.fetch(FetchDescriptor<Account>()).first)
        #expect(refreshed.balanceMinorUnits == 777)
        let pendingAfter = try #require(try context.fetch(FetchDescriptor<LedgerTransaction>())
            .first { $0.bankTransactionID == "P-1" })
        #expect(pendingAfter.isPending)
        #expect(pendingAfter.pendingMismatchCount == 0)
    }

    @Test("Backfill reports more to fetch when it spends the page cap")
    func backfillStopsAtPageLimit() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let credentialID = UUID()
        insertHolder(in: context, credentialID: credentialID)
        let child = insertConnection(in: context, credentialID: credentialID, connectionID: "CON-1", orgID: "ORG-1")
        let account = insertAccount(in: context, bankAccountID: "1", institution: child, balance: 500)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        insertPosted(in: context, id: "T-NEW", daysAgo: 5, account: account, now: now)
        try context.save()

        let stub = StubFetch { _, _ in
            self.accountSet([self.posted("T-OLD", daysAgo: 400, now: now)])
        }

        let outcome = await engine.backfillHistory(
            institutionID: try holder(in: context).persistentModelID,
            accessURL: accessURL(),
            fetch: { url, start, end in try await stub.fetch(url, start, end) },
            maxPages: 2,
            now: now,
            calendar: calendar()
        )
        #expect(outcome.pagesFetched == 2)
        #expect(!outcome.reachedFloor)
        #expect(outcome.hitPageLimit)
    }
}

/// A fetch closure that records the windows it was asked for.
private final class StubFetch: @unchecked Sendable {
    struct Call {
        let start: Date
        let end: Date
    }

    private(set) var calls: [Call] = []
    private let respond: (Date, Date) -> SimpleFINAccountSet

    init(respond: @escaping (Date, Date) -> SimpleFINAccountSet) {
        self.respond = respond
    }

    func fetch(_ url: URL, _ start: Date, _ end: Date) async throws -> SimpleFINAccountSet {
        calls.append(Call(start: start, end: end))
        return respond(start, end)
    }
}
