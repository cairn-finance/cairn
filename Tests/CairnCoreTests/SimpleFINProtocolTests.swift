import Foundation
import Testing
@testable import CairnCore

@Suite("SimpleFIN protocol")
struct SimpleFINProtocolTests {
    @Test("Decodes a v2 account set")
    func decodesAccountSet() throws {
        let json = """
        {
          "errlist": [
            { "code": "con.auth", "msg": "Authentication failed for My Bank", "conn_id": "CON-1" }
          ],
          "connections": [
            {
              "conn_id": "CON-1",
              "name": "My Bank - Jeff",
              "org_id": "INST-9",
              "org_name": "My Bank",
              "org_url": "https://mybank.com",
              "sfin_url": "https://sfin.mybank.com"
            }
          ],
          "accounts": [
            {
              "id": "2930002",
              "name": "Savings",
              "conn_id": "CON-1",
              "conn_name": "My Bank - Jeff",
              "currency": "USD",
              "balance": "100.23",
              "available-balance": "75.23",
              "balance-date": 978366153,
              "transactions": [
                {
                  "id": "T1",
                  "posted": 793090572,
                  "amount": "-33293.43",
                  "description": "Uncle Frank's Bait Shop"
                },
                {
                  "id": "T2",
                  "posted": 0,
                  "amount": "12.00",
                  "description": "Pending charge",
                  "pending": true
                }
              ]
            }
          ]
        }
        """
        let dto = try JSONDecoder().decode(SimpleFINAccountSetDTO.self, from: Data(json.utf8))
        let set = dto.toDomain()

        #expect(set.connections.count == 1)
        #expect(set.connections.first?.id == "CON-1")
        #expect(set.connections.first?.organizationName == "My Bank")
        #expect(set.errors.count == 1)
        #expect(set.errors.first?.prefix == "con")

        let account = try #require(set.accounts.first)
        #expect(account.id == "2930002")
        #expect(account.currency.code == "USD")
        #expect(account.balanceMinorUnits == 10_023)
        #expect(account.availableBalanceMinorUnits == 7_523)
        #expect(account.transactions.count == 2)

        let posted = try #require(account.transactions.first { $0.id == "T1" })
        #expect(posted.amountMinorUnits == -3_329_343)
        #expect(posted.postedDate != nil)

        let pending = try #require(account.transactions.first { $0.id == "T2" })
        #expect(pending.isPending)
        // `posted: 0` is not a meaningful date.
        #expect(pending.postedDate == nil)
    }

    @Test("Treats custom currency URLs as custom currencies")
    func customCurrency() throws {
        let json = """
        { "accounts": [ { "id": "A", "name": "Miles", "currency": "https://example.com/miles", "balance": "1000" } ] }
        """
        let dto = try JSONDecoder().decode(SimpleFINAccountSetDTO.self, from: Data(json.utf8))
        let account = try #require(dto.toDomain().accounts.first)
        #expect(account.currency.isCustom)
    }

    @Test("Builds the accounts URL with credentials out of the URL")
    func accountsRequestURL() throws {
        let access = try #require(URL(string: "https://user:pass@bridge.example.com/simplefin"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (credentials, url) = SimpleFINClient.accountsRequestURL(
            accessURL: access,
            startDate: date,
            includePending: true
        )

        #expect(credentials == Data("user:pass".utf8).base64EncodedString())
        #expect(url.absoluteString.contains("://bridge.example.com/simplefin/accounts"))
        #expect(!url.absoluteString.contains("user"))
        #expect(!url.absoluteString.contains("pass"))

        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains { $0.name == "version" && $0.value == "2" })
        #expect(query.contains { $0.name == "pending" && $0.value == "1" })
        #expect(query.contains { $0.name == "start-date" && $0.value == "1700000000" })
    }

    @Test("Decodes a setup token, tolerating whitespace and padding")
    func decodesToken() {
        let url = "https://bridge.simplefin.org/simplefin/claim/demo"
        let encoded = Data(url.utf8).base64EncodedString()
        #expect(SimpleFINClient.decodeToken(encoded)?.absoluteString == url)

        let wrapped = encoded.prefix(10) + "\n" + encoded.dropFirst(10) + "\n"
        #expect(SimpleFINClient.decodeToken(String(wrapped))?.absoluteString == url)
    }

    @Test("Rejects a non-token")
    func rejectsBadToken() {
        #expect(SimpleFINClient.decodeToken("not base64!!") == nil)
        #expect(SimpleFINClient.decodeToken("") == nil)
    }
}

@Suite("Error sanitizer")
struct ErrorSanitizerTests {
    @Test("Strips markup and control characters")
    func stripsMarkup() {
        let raw = "<b>Bad</b>\u{0000} thing\n\there"
        let clean = ErrorSanitizer.sanitize(raw)
        #expect(!clean.contains("<"))
        #expect(!clean.contains(">"))
        #expect(!clean.contains("\u{0000}"))
        #expect(clean == "Bad thing here")
    }

    @Test("Truncates very long messages")
    func truncates() {
        let raw = String(repeating: "a", count: 1000)
        let clean = ErrorSanitizer.sanitize(raw)
        #expect(clean.count <= ErrorSanitizer.maximumLength + 1)
    }
}
