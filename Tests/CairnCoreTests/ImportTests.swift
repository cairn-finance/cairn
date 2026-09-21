import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("Merchant normalization")
struct MerchantNormalizerTests {
    @Test("Strips processor prefixes and keeps the merchant")
    func processorPrefixes() {
        #expect(MerchantNormalizer.normalize("SQ *BLUE BOTTLE COFFEE 1234") == "BLUE BOTTLE COFFEE")
        #expect(MerchantNormalizer.normalize("PAYPAL *SPOTIFY") == "SPOTIFY")
        #expect(MerchantNormalizer.normalize("TST* Chipotle") == "Chipotle")
    }

    @Test("Maps the Amazon family to one name")
    func amazon() {
        #expect(MerchantNormalizer.normalize("AMZN Mktp US*2A3B4C") == "Amazon")
        #expect(MerchantNormalizer.normalize("AMAZON.COM*AB12") == "Amazon")
    }

    @Test("Strips ACH and other protocol labels")
    func protocolLabels() {
        #expect(MerchantNormalizer.normalize("ACH: PAYPAL *SPOTIFY") == "SPOTIFY")
        #expect(MerchantNormalizer.normalize("ACH: ACME PAYROLL") == "ACME PAYROLL")
        #expect(MerchantNormalizer.normalize("ACH DEBIT VANGUARD") == "VANGUARD")
        #expect(MerchantNormalizer.normalize("POS: WHOLE FOODS #12") == "WHOLE FOODS")
    }

    @Test("Removes store numbers and trailing state")
    func storeAndState() {
        #expect(MerchantNormalizer.normalize("STARBUCKS STORE 12345") == "STARBUCKS STORE")
        #expect(MerchantNormalizer.normalize("WHOLE FOODS MKT SEATTLE WA") == "WHOLE FOODS MKT SEATTLE")
    }

    @Test("Grouping key is case-insensitive")
    func groupingKey() {
        #expect(MerchantNormalizer.groupingKey("Starbucks 00123") == MerchantNormalizer.groupingKey("STARBUCKS"))
    }

    @Test("Empty input is safe")
    func empty() {
        #expect(MerchantNormalizer.normalize("") == "")
        #expect(MerchantNormalizer.normalize("   ") == "")
    }
}

@Suite("CSV parsing")
struct CSVParserTests {
    @Test("Handles quoted commas and escaped quotes")
    func quoting() {
        let document = CSVParser.parse("a,b\n\"x, y\",\"say \"\"hi\"\"\"\n")
        #expect(document.headers == ["a", "b"])
        #expect(document.dataRows == [["x, y", "say \"hi\""]])
    }

    @Test("Tolerates CRLF and a trailing blank line")
    func crlf() {
        let document = CSVParser.parse("a,b\r\n1,2\r\n\r\n")
        #expect(document.dataRows == [["1", "2"]])
    }

    @Test("Sniffs semicolons")
    func semicolonSniff() {
        let document = CSVParser.parse("date;description;amount\n2026-01-01;Coffee;-3,50\n")
        #expect(document.delimiter == ";")
        #expect(document.headers == ["date", "description", "amount"])
    }

    @Test("Strips a UTF-8 BOM")
    func bom() {
        let document = CSVParser.parse("\u{FEFF}a,b\n1,2\n")
        #expect(document.headers == ["a", "b"])
    }
}

@Suite("CSV import")
struct CSVImportTests {
    private let appleCard = """
    Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
    09/01/2026,09/02/2026,"WHOLE FOODS MKT #123",Whole Foods,Groceries,Transactions,-84.32,Sehej
    09/02/2026,09/03/2026,BLUE BOTTLE COFFEE,Blue Bottle,Dining,Transactions,-6.75,Sehej
    09/03/2026,09/04/2026,Payment,Apple,Payments,Payments,1204.32,Sehej
    """

    @Test("Resolves Apple Card headers")
    func resolvesAppleCard() throws {
        let document = CSVParser.parse(appleCard)
        let mapping = try #require(CSVColumnResolver.resolve(headers: document.headers, preset: .appleCard))
        #expect(mapping.dateColumn == "Transaction Date")
        #expect(mapping.merchantColumn == "Merchant")
        #expect(mapping.descriptionColumn == "Description")
        #expect(mapping.amountColumn == "Amount (USD)")
    }

    @Test("Parses Apple Card rows into signed minor units")
    func parsesAppleCard() throws {
        let document = CSVParser.parse(appleCard)
        let mapping = try #require(CSVColumnResolver.resolve(headers: document.headers, preset: .appleCard))
        let result = CSVImportParser.parse(document, mapping: mapping, currency: .usd)

        #expect(result.skippedRows == 0)
        #expect(result.transactions.count == 3)
        #expect(result.transactions[0].amountMinorUnits == -8_432)
        #expect(result.transactions[1].amountMinorUnits == -675)
        #expect(result.transactions[2].amountMinorUnits == 120_432)

        let calendar = Calendar(identifier: .gregorian)
        let first = result.transactions[0].date
        #expect(calendar.component(.month, from: first) == 9)
        #expect(calendar.component(.day, from: first) == 1)
        #expect(calendar.component(.year, from: first) == 2026)
    }

    @Test("Handles debit and credit columns")
    func debitCredit() {
        let text = "Date,Description,Debit,Credit\n2026-01-01,Coffee,3.50,\n2026-01-02,Refund,,5.00\n"
        let document = CSVParser.parse(text)
        let mapping = CSVImportMapping(
            dateColumn: "Date",
            descriptionColumn: "Description",
            debitColumn: "Debit",
            creditColumn: "Credit",
            dateFormat: .yearMonthDay
        )
        let result = CSVImportParser.parse(document, mapping: mapping, currency: .usd)
        #expect(result.transactions.map(\.amountMinorUnits) == [-350, 500])
    }

    @Test("Parses accounting parentheses and a flip-sign toggle")
    func amountFormats() {
        #expect(CSVImportParser.parseAmount("(12.34)", flipsSign: false, exponent: 2) == -1_234)
        #expect(CSVImportParser.parseAmount("$1,234.56", flipsSign: false, exponent: 2) == 123_456)
        #expect(CSVImportParser.parseAmount("12.34", flipsSign: true, exponent: 2) == -1_234)
        #expect(CSVImportParser.parseAmount("-12.34", flipsSign: true, exponent: 2) == 1_234)
    }

    @Test("Resolves a generic CSV")
    func resolvesGeneric() throws {
        let document = CSVParser.parse("Posted Date,Memo,Amount\n2026-01-01,Coffee,-3.50\n")
        let mapping = try #require(CSVColumnResolver.resolve(headers: document.headers, preset: .generic))
        #expect(mapping.dateColumn == "Posted Date")
        #expect(mapping.descriptionColumn == "Memo")
        #expect(mapping.amountColumn == "Amount")
    }
}

@Suite("Transaction import")
@MainActor
struct TransactionImportTests {
    private func makeManualAccount(in context: ModelContext) -> Account {
        let account = Account(bankAccountID: "manual-1", name: "Apple Card", currency: .usd)
        account.sourceRaw = AccountSource.manual.rawValue
        account.accountTypeRaw = AccountType.credit.rawValue
        context.insert(account)
        return account
    }

    @Test("Inserts imported rows and recomputes the manual balance")
    func insertAndBalance() async throws {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        let context = result.container.mainContext
        let account = makeManualAccount(in: context)
        try context.save()

        let engine = SyncEngine(modelContainer: result.container)
        let imports = [
            ImportedTransaction(date: Date(), description: "Whole Foods", merchant: "Whole Foods", amountMinorUnits: -8_432),
            ImportedTransaction(date: Date(), description: "Payment", merchant: "Apple", amountMinorUnits: 10_000),
        ]
        let outcome = try await engine.importTransactions(imports, intoAccountID: account.persistentModelID)

        #expect(outcome.inserted == 2)
        #expect(outcome.duplicatesSkipped == 0)
        // The actor writes on its own context; refetch to see the merged value.
        let refreshed = try context.fetch(FetchDescriptor<Account>()).first
        #expect(refreshed?.balanceMinorUnits == 1_568)
    }

    @Test("Skips duplicates on re-import")
    func deduplication() async throws {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        let context = result.container.mainContext
        let account = makeManualAccount(in: context)
        try context.save()

        let engine = SyncEngine(modelContainer: result.container)
        let day = Date()
        let imports = [
            ImportedTransaction(date: day, description: "Blue Bottle Coffee", merchant: "Blue Bottle", amountMinorUnits: -675),
        ]
        _ = try await engine.importTransactions(imports, intoAccountID: account.persistentModelID)
        let second = try await engine.importTransactions(imports, intoAccountID: account.persistentModelID)

        #expect(second.inserted == 0)
        #expect(second.duplicatesSkipped == 1)
        let count = try context.fetchCount(FetchDescriptor<LedgerTransaction>())
        #expect(count == 1)
    }

    @Test("Re-importing after an edit keeps one row and preserves the edit")
    func reimportAfterEditKeepsIdentity() async throws {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        let context = result.container.mainContext
        let account = makeManualAccount(in: context)
        try context.save()

        let engine = SyncEngine(modelContainer: result.container)
        let day = Date()
        let imports = [
            ImportedTransaction(date: day, description: "Blue Bottle Coffee", merchant: "Blue Bottle", amountMinorUnits: -675),
        ]
        let first = try await engine.importTransactions(imports, intoAccountID: account.persistentModelID)
        #expect(first.inserted == 1)

        let row = try #require(try context.fetch(FetchDescriptor<LedgerTransaction>()).first)
        let identifier = row.bankTransactionID
        // Edit the amount too, so the row no longer matches on content at all and
        // only the deterministic identity can prevent a second insert.
        try await engine.updateManualTransaction(
            ManualEntry(payee: "Blue Bottle (edited)", amountMinorUnits: -999, date: day),
            transactionID: row.persistentModelID
        )

        let second = try await engine.importTransactions(imports, intoAccountID: account.persistentModelID)
        #expect(second.inserted == 0)
        #expect(second.duplicatesSkipped == 1)

        let rows = try context.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(rows.count == 1)
        let refreshed = try #require(rows.first)
        #expect(refreshed.bankTransactionID == identifier)
        #expect(refreshed.payeeDescription == "Blue Bottle (edited)")
        #expect(refreshed.amountMinorUnits == -999)
    }
}
