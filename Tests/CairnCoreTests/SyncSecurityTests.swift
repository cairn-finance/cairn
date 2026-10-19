import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("SimpleFIN security boundaries")
@MainActor
struct SyncSecurityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let origin = "https://bank.example"

    private func accessURL(_ value: String = "https://bank.example") throws -> URL {
        try #require(URL(string: value))
    }

    private struct Fixture {
        let container: ModelContainer
        let engine: SyncEngine
        let holder: Institution
        let bank: Institution
        let account: Account
    }

    private func fixture(org: String = "ORG") throws -> Fixture {
        let container = try ModelContainerFactory.make(mode: .local, inMemory: true).container
        let context = container.mainContext
        let holder = Institution(bankConnectionID: "", name: "Saved", credentialID: UUID())
        holder.sfinURL = origin
        let bank = Institution(bankConnectionID: "CON", name: "Bank", credentialID: holder.credentialID)
        bank.orgID = org
        let account = Account(bankAccountID: "ACCOUNT", name: "Account", currency: .usd)
        account.institution = bank
        account.balanceMinorUnits = 123
        context.insert(holder)
        context.insert(bank)
        context.insert(account)
        try context.save()
        return Fixture(container: container, engine: SyncEngine(modelContainer: container),
                       holder: holder, bank: bank, account: account)
    }

    private func transaction(_ id: String, pending: Bool, dated: Bool = true) -> SimpleFINTransaction {
        SimpleFINTransaction(id: id, postedDate: pending || !dated ? nil : now,
                             transactedAt: dated ? now : nil, amountMinorUnits: -100,
                             description: "Example merchant", isPending: pending)
    }

    private func response(_ transactions: [SimpleFINTransaction], connection: String = "CON",
                          org: String = "ORG", balance: Int64 = 999) -> SimpleFINAccountSet {
        SimpleFINAccountSet(
            connections: [SimpleFINConnection(id: connection, name: "Incoming", organizationID: org,
                                             simpleFINURL: "https://spoofed.example")],
            accounts: [SimpleFINAccount(id: "ACCOUNT", name: "Incoming", connectionID: connection,
                                       currency: .usd, balanceMinorUnits: balance, transactions: transactions)]
        )
    }

    @discardableResult
    private func sync(_ fixture: Fixture, _ transactions: [SimpleFINTransaction]) async throws -> SyncOutcome {
        try await fixture.engine.applyAccountSet(response(transactions),
            institutionID: fixture.holder.persistentModelID, accessURL: try accessURL(), now: now)
    }

    private func rows(_ fixture: Fixture) throws -> [LedgerTransaction] {
        try fixture.container.mainContext.fetch(FetchDescriptor<LedgerTransaction>())
    }

    @Test("A posted row cannot regress through sync, claim, or backfill", arguments: ["sync", "claim", "backfill"])
    func postedStateIsMonotonic(path: String) async throws {
        let f = try fixture()
        _ = try await sync(f, [transaction("POSTED", pending: false)])
        let row = try #require(try rows(f).first)
        row.note = "Keep this annotation"
        try f.container.mainContext.save()
        let payload = response([transaction("POSTED", pending: true), transaction("FAKE", pending: false)])
        switch path {
        case "claim":
            let probe = SyncEngine.ConnectionProbe(accountSet: payload,
                adoption: .adopt(credentialID: f.holder.credentialID), credentialID: f.holder.credentialID)
            _ = try await f.engine.applyClaim(probe, accessURL: try accessURL(), now: now)
        case "backfill":
            let result = await f.engine.backfillHistory(institutionID: f.holder.persistentModelID,
                accessURL: try accessURL(), cursor: now, targetDate: now.addingTimeInterval(-86_400),
                fetch: { _, _, _ in payload }, maxPages: 1, now: now)
            #expect(result.failure == nil)
        default:
            _ = try await f.engine.applyAccountSet(payload, institutionID: f.holder.persistentModelID,
                accessURL: try accessURL(), now: now)
        }
        for _ in 0..<3 { _ = try await sync(f, [transaction("OTHER", pending: false)]) }
        let saved = try #require(try rows(f).first { $0.bankTransactionID == "POSTED" })
        #expect(!saved.isPending)
        #expect(saved.postedDate == now)
        #expect(saved.note == "Keep this annotation")
        #expect(try rows(f).first { $0.bankTransactionID == "FAKE" }?.note == nil)
    }

    @Test("Annotations are neither deleted nor moved by pending reconciliation",
          arguments: ["note", "category", "tags", "transfer", "ignored", "reviewed", "settlement"])
    func pendingAnnotationsStayOnTheirRow(annotation: String) async throws {
        let f = try fixture()
        _ = try await sync(f, [transaction("PENDING", pending: true)])
        let context = f.container.mainContext
        let pending = try #require(try rows(f).first)
        switch annotation {
        case "note": pending.note = "Keep"
        case "category":
            let category = Category(name: "Chosen")
            context.insert(category)
            pending.userCategory = category
        case "tags":
            let tag = Tag(name: "Chosen")
            context.insert(tag)
            pending.tags = [tag]
        case "transfer": pending.isTransferUserSet = true
        case "ignored": pending.isIgnored = true
        case "reviewed": pending.reviewedAt = now
        default: pending.settlementID = UUID()
        }
        try context.save()
        // Even an identical posted description cannot authorize moving annotations.
        let promoted = try await sync(f, [transaction("POSTED", pending: false)])
        #expect(promoted.pendingPromoted == 0)
        for _ in 0..<3 {
            _ = try await sync(f, [])
            _ = try await sync(f, [transaction("OTHER", pending: false)])
        }
        let remaining = try rows(f)
        #expect(remaining.contains { $0.bankTransactionID == "PENDING" })
        let posted = try #require(remaining.first { $0.bankTransactionID == "POSTED" })
        #expect(posted.note == nil && posted.userCategory == nil && (posted.tags ?? []).isEmpty)
        #expect(!posted.isTransferUserSet && !posted.isIgnored && posted.reviewedAt == nil)
        #expect(posted.settlementID == nil)
    }

    @Test("An empty response does not age pending rows")
    func emptyResponseIsNotCancellation() async throws {
        let f = try fixture()
        _ = try await sync(f, [transaction("PENDING", pending: true)])
        for _ in 0..<3 { _ = try await sync(f, []) }
        let pending = try #require(try rows(f).first)
        #expect(pending.pendingMismatchCount == 0)
        #expect(pending.isPending)
    }

    @Test("Same-id posting preserves annotations")
    func sameIDPostingPreservesAnnotations() async throws {
        let f = try fixture()
        _ = try await sync(f, [transaction("SAME", pending: true)])
        let pending = try #require(try rows(f).first)
        pending.note = "Keep"
        try f.container.mainContext.save()
        _ = try await sync(f, [transaction("SAME", pending: false)])
        let saved = try #require(try rows(f).first)
        #expect(!saved.isPending && saved.note == "Keep")
        #expect(try rows(f).count == 1)
    }

    @Test("Pending promotion requires dates, absence, and an unambiguous match",
          arguments: ["valid", "undated", "stillReported", "twoPending", "twoPosted"])
    func promotionConstraints(scenario: String) async throws {
        let f = try fixture()
        var pending = [transaction("P1", pending: true, dated: scenario != "undated")]
        if scenario == "twoPending" { pending.append(transaction("P2", pending: true)) }
        _ = try await sync(f, pending)
        var posted = [transaction("S1", pending: false)]
        if scenario == "stillReported" { posted += pending }
        if scenario == "twoPosted" { posted.append(transaction("S2", pending: false)) }
        let outcome = try await sync(f, posted)
        #expect(outcome.pendingPromoted == (scenario == "valid" ? 1 : 0))
        #expect(try rows(f).contains { $0.bankTransactionID == "P1" } == (scenario != "valid"))
    }

    @Test("Pending deletion is counted when only an unannotated stale row is removed")
    func ageOutIsCounted() async throws {
        let f = try fixture()
        _ = try await sync(f, [transaction("P", pending: true)])
        let unrelated = SimpleFINTransaction(id: "OTHER", postedDate: now, transactedAt: now,
            amountMinorUnits: -999, description: "Unrelated", isPending: false)
        _ = try await sync(f, [unrelated])
        let outcome = try await sync(f, [unrelated])
        #expect(outcome.stalePendingRemoved == 1)
        #expect(outcome.hadChanges)
    }

    @Test("A server error cannot retire pending rows from an incomplete response")
    func errorResponsePreservesPending() async throws {
        let f = try fixture()
        _ = try await sync(f, [transaction("P", pending: true)])
        let partial = response([transaction("OTHER", pending: false)])
        let payload = SimpleFINAccountSet(connections: partial.connections, accounts: partial.accounts,
            errors: [SimpleFINServerError(code: "error", message: "Incomplete aggregation")])
        for _ in 0..<3 {
            _ = try await f.engine.applyAccountSet(payload, institutionID: f.holder.persistentModelID,
                accessURL: try accessURL(), now: now)
        }
        #expect(try rows(f).contains { $0.bankTransactionID == "P" })
    }

    @Test("Sync cannot write across credentials, including legacy orgless rows", arguments: ["ORG", ""])
    func foreignSyncCannotMutateVictim(org: String) async throws {
        let f = try fixture(org: org)
        let context = f.container.mainContext
        let attacker = Institution(bankConnectionID: "", name: "Other server", credentialID: UUID())
        attacker.sfinURL = "https://other.example"
        context.insert(attacker)
        let original = LedgerTransaction(bankTransactionID: "COLLISION", payeeDescription: "Original", amountMinorUnits: -123)
        original.account = f.account
        original.accountIDIndex = f.account.bankAccountID
        original.note = "Keep"
        context.insert(original)
        try context.save()
        for _ in 0..<3 {
            _ = try await f.engine.applyAccountSet(response([transaction("COLLISION", pending: true)]),
                institutionID: attacker.persistentModelID, accessURL: try accessURL("https://other.example"), now: now)
        }
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let victim = try #require(accounts.first { $0.institution?.credentialID == f.holder.credentialID })
        #expect(victim.balanceMinorUnits == 123)
        #expect(victim.institution?.orgID == org)
        let saved = try #require(try rows(f).first { $0.account?.persistentModelID == victim.persistentModelID })
        #expect(saved.payeeDescription == "Original" && saved.note == "Keep" && !saved.isPending)
        #expect(accounts.count == 2)
        #expect(try rows(f).count == 2)
    }

    @Test("Backfill cannot resolve a foreign account id")
    func backfillCannotUseForeignAccount() async throws {
        let f = try fixture()
        let attacker = Institution(bankConnectionID: "", name: "Other", credentialID: UUID())
        f.container.mainContext.insert(attacker)
        try f.container.mainContext.save()
        let payload = response([transaction("INJECTED", pending: false)])
        let outcome = await f.engine.backfillHistory(institutionID: attacker.persistentModelID,
            accessURL: try accessURL("https://other.example"), cursor: now,
            targetDate: now.addingTimeInterval(-86_400), fetch: { _, _, _ in payload }, maxPages: 1, now: now)
        #expect(outcome.unresolvedAccounts == 1)
        #expect(outcome.failure != nil)
        #expect(try rows(f).isEmpty)
    }

    @Test("A fresh claim imports only into its own credential, even for forged identities")
    func freshClaimCannotWriteForeignData() async throws {
        let f = try fixture()
        let proposed = UUID()
        let probe = SyncEngine.ConnectionProbe(accountSet: response([transaction("FORGED", pending: false)]),
            adoption: .fresh, credentialID: proposed)
        _ = try await f.engine.applyClaim(probe, accessURL: try accessURL("https://other.example"), now: now)
        let context = f.container.mainContext
        let accounts = try context.fetch(FetchDescriptor<Account>())
        #expect(accounts.count == 2)
        #expect(accounts.first { $0.institution?.credentialID == f.holder.credentialID }?.balanceMinorUnits == 123)
        #expect(try rows(f).allSatisfy { $0.account?.institution?.credentialID == proposed })
        let institutions = try context.fetch(FetchDescriptor<Institution>())
        #expect(institutions.contains { $0.credentialID == proposed && !$0.bankConnectionID.isEmpty })
    }

    @Test("Backfill cannot use the same credential's account under a different connection")
    func backfillRequiresAccountConnection() async throws {
        let f = try fixture()
        let payload = response([transaction("FORGED", pending: false)], connection: "WRONG")
        let outcome = await f.engine.backfillHistory(institutionID: f.holder.persistentModelID,
            accessURL: try accessURL(), cursor: now, targetDate: now.addingTimeInterval(-86_400),
            fetch: { _, _, _ in payload }, maxPages: 1, now: now)
        #expect(outcome.unresolvedAccounts == 1)
        #expect(try rows(f).isEmpty)
    }

    @Test("A claim from another server cannot adopt an exact identity")
    func claimNeedsTrustedOrigin() async throws {
        let f = try fixture()
        let stored = try await f.engine.storedConnections()
        #expect(ConnectionMatcher.decide(incoming: response([]).connections, stored: stored,
            serverOrigin: "https://other.example") == .fresh)
        #expect(ConnectionMatcher.decide(incoming: response([]).connections, stored: stored,
            serverOrigin: origin) == .adopt(credentialID: f.holder.credentialID))
        let probe = SyncEngine.ConnectionProbe(accountSet: response([]),
            adoption: .adopt(credentialID: f.holder.credentialID), credentialID: f.holder.credentialID)
        await #expect(throws: SimpleFINError.connectionConflict) {
            try await f.engine.applyClaim(probe, accessURL: try accessURL("https://other.example"), now: now)
        }
    }

    @Test("Repair cannot merge data based on a foreign or missing holder", arguments: ["foreign", "missing", "unknown"])
    func repairRequiresProvenance(scenario: String) async throws {
        let f = try fixture()
        let context = f.container.mainContext
        let credential = UUID()
        if scenario != "missing" {
            let holder = Institution(bankConnectionID: "", name: "Other", credentialID: credential)
            holder.sfinURL = scenario == "unknown" ? "" : "https://other.example"
            context.insert(holder)
        }
        let bank = Institution(bankConnectionID: "CON", name: "Forged", credentialID: credential)
        bank.orgID = "ORG"
        // Server-authored metadata is not evidence of a common server.
        bank.sfinURL = origin
        bank.createdAt = .distantPast
        context.insert(bank)
        let otherAccount = Account(bankAccountID: "ACCOUNT", name: "Other", currency: .usd)
        otherAccount.institution = bank
        context.insert(otherAccount)
        let plan = BudgetSmoothingPlan(accountIDIndex: "ACCOUNT", bankTransactionID: "POSTED", name: "Keep")
        context.insert(plan)
        try context.save()
        let outcome = try await f.engine.repairDuplicateConnections()
        #expect(outcome.indeterminateGroups == 1)
        #expect(!outcome.didChange && outcome.retiredCredentials.isEmpty)
        #expect(try await f.engine.redundantCredentialIDs().isEmpty)
        let removal = try await f.engine.removeConnections(credentialIDs: [credential])
        #expect(removal.movedAccounts == 0 && removal.mergedAccounts == 0)
        #expect(try context.fetch(FetchDescriptor<Account>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<BudgetSmoothingPlan>()).count == 1)
    }

    @Test("Re-keying refuses to overwrite or delete secrets from a different origin")
    func rekeyRejectsForeignOrigin() throws {
        let store = InMemoryCredentialStore()
        let old = UUID()
        let survivor = UUID()
        try store.store("https://other.example/token", id: old, synchronizable: false)
        try store.store("https://bank.example/token", id: survivor, synchronizable: false)
        #expect(throws: SimpleFINError.connectionConflict) {
            try CredentialReKey.move(store: store, from: old, to: survivor,
                synchronizable: false)
        }
        #expect(try store.secret(for: old) == "https://other.example/token")
        #expect(try store.secret(for: survivor) == "https://bank.example/token")
    }

    @Test("Origin comparison normalizes HTTPS ports and omits bearer credentials")
    func normalizedOrigins() {
        #expect(SimpleFINServerOrigin.normalized("https://user:secret@EXAMPLE.com/path") == "https://example.com:443")
        #expect(SimpleFINServerOrigin.normalized("https://example.com:443/path") == "https://example.com:443")
        #expect(SimpleFINServerOrigin.normalized("https://example.com:8443/path") == "https://example.com:8443")
        #expect(SimpleFINServerOrigin.normalized("http://example.com") == nil)
    }
}
