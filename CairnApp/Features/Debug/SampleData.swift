#if DEBUG
import Foundation
import SwiftData
import CairnCore

/// Debug-only fixtures. Populated when the app is launched with
/// `--cairn-sample-data`, so UI can be exercised without a live SimpleFIN token.
/// Never compiled into release builds.
enum SampleData {
    static let launchArgument = "--cairn-sample-data"

    static func populate(context: ModelContext) {
        // Seed only once, even if the app is relaunched with the flag.
        let existing = (try? context.fetchCount(FetchDescriptor<Institution>())) ?? 0
        guard existing == 0 else { return }

        let calendar = Calendar.current
        let now = Date()

        let defaults = (try? context.fetch(FetchDescriptor<CairnCore.Category>())) ?? []
        func category(_ name: String) -> CairnCore.Category? {
            defaults.first { $0.name == name }
        }

        let institution = Institution(
            bankConnectionID: "CON-DEMO",
            name: "SimpleFIN Bridge Demo",
            orgID: "ORG-DEMO",
            orgURL: "https://example.com",
            sfinURL: "https://bridge.simplefin.org"
        )
        institution.lastSyncDate = now
        context.insert(institution)

        let checking = Account(bankAccountID: "ACT-CHK", name: "Everyday Checking", currency: .usd)
        checking.accountTypeRaw = AccountType.checking.rawValue
        checking.balanceMinorUnits = 421_355
        checking.availableBalanceMinorUnits = 410_000
        checking.hasAvailableBalance = true
        checking.balanceDate = now
        checking.institution = institution
        checking.lastSyncedAt = now
        context.insert(checking)

        let savings = Account(bankAccountID: "ACT-SAV", name: "High-Yield Savings", currency: .usd)
        savings.accountTypeRaw = AccountType.savings.rawValue
        savings.balanceMinorUnits = 1_894_012
        savings.balanceDate = now
        savings.institution = institution
        savings.lastSyncedAt = now
        context.insert(savings)

        let brokerage = Account(bankAccountID: "ACT-INV", name: "Brokerage", currency: .usd)
        brokerage.accountTypeRaw = AccountType.investment.rawValue
        brokerage.balanceMinorUnits = 3_450_000
        brokerage.balanceDate = now
        brokerage.institution = institution
        brokerage.lastSyncedAt = now
        context.insert(brokerage)

        insertHolding(
            into: brokerage, id: "H-AAPL", symbol: "AAPL", name: "Shares of Apple",
            shares: "100", market: 2_000_000, cost: 1_200_000, order: 0, context: context
        )
        insertHolding(
            into: brokerage, id: "H-VTI", symbol: "VTI", name: "Vanguard Total Stock Market ETF",
            shares: "50", market: 1_450_000, cost: 1_100_000, order: 1, context: context
        )

        let retirement = Account(bankAccountID: "ACT-IRA", name: "Roth IRA", currency: .usd)
        retirement.accountTypeRaw = AccountType.investment.rawValue
        retirement.balanceMinorUnits = 8_120_500
        retirement.balanceDate = now
        retirement.institution = institution
        retirement.lastSyncedAt = now
        context.insert(retirement)

        insertHolding(
            into: retirement, id: "H-VFIAX", symbol: "VFIAX", name: "Vanguard 500 Index Fund",
            shares: "1000", market: 8_120_500, cost: 6_000_000, order: 0, context: context
        )

        let european = Account(bankAccountID: "ACT-EU", name: "European Equities", currency: Currency(code: "EUR"))
        european.accountTypeRaw = AccountType.investment.rawValue
        european.balanceMinorUnits = 1_200_000
        european.balanceDate = now
        european.institution = institution
        european.lastSyncedAt = now
        context.insert(european)

        insertHolding(
            into: european, id: "H-ASML", symbol: "ASML", name: "ASML Holding N.V.",
            shares: "20", market: 1_200_000, cost: 980_000, order: 0,
            currency: Currency(code: "EUR"), context: context
        )

        let card = Account(bankAccountID: "ACT-CC", name: "Travel Card", currency: .usd)
        card.accountTypeRaw = AccountType.credit.rawValue
        card.balanceMinorUnits = -120_432
        card.balanceDate = now
        card.institution = institution
        card.lastSyncedAt = now
        context.insert(card)

        // swiftlint:disable:next large_tuple
        let samples: [(String, Int64, String, String, Int)] = [
            ("Payroll Deposit", 512_500, "Income", "ACT-CHK", -1),
            ("Whole Foods Market", -8_432, "Groceries", "ACT-CC", -2),
            ("Blue Bottle Coffee", -675, "Dining", "ACT-CC", -2),
            ("Shell Gas Station", -5_412, "Transport", "ACT-CC", -3),
            ("Rent Payment", -195_000, "Housing", "ACT-CHK", -5),
            ("Pacific Gas & Electric", -12_300, "Utilities", "ACT-CHK", -6),
            ("Amazon.com", -4_299, "Shopping", "ACT-CC", -7),
            ("Netflix", -1_549, "Entertainment", "ACT-CC", -8),
            ("Kaiser Pharmacy", -3_275, "Health", "ACT-CC", -9),
            ("Transfer to Savings", -50_000, "Transfers", "ACT-CHK", -10),
            ("Safeway", -7_812, "Groceries", "ACT-CC", -12),
            ("United Airlines", -42_600, "Travel", "ACT-CC", -14),
            ("Chipotle", -1_480, "Dining", "ACT-CC", -15),
            ("Payroll Deposit", 512_500, "Income", "ACT-CHK", -16),
            ("Uber", -2_350, "Transport", "ACT-CC", -17),
            ("Apple Store", -129_900, "Shopping", "ACT-CC", -20),
            ("Spotify", -1_199, "Entertainment", "ACT-CC", -22),
            ("Interest Payment", 1_240, "Income", "ACT-SAV", -25),
            ("Costco", -23_450, "Groceries", "ACT-CC", -28),
            ("State Farm", -14_200, "Housing", "ACT-CHK", -30),
            ("Delta Airlines", -55_300, "Travel", "ACT-CC", -34),
            ("Local Diner", -2_890, "Dining", "ACT-CC", -36),
            ("Payroll Deposit", 512_500, "Income", "ACT-CHK", -37),
            ("Home Depot", -9_876, "Shopping", "ACT-CC", -40),
            ("Verizon Wireless", -8_500, "Utilities", "ACT-CHK", -44),
            ("Trader Joe's", -6_543, "Groceries", "ACT-CC", -48),
            ("Gym Membership", -4_900, "Health", "ACT-CC", -52),
            ("Transfer to Savings", -50_000, "Transfers", "ACT-CHK", -55),
            ("Steam", -5_999, "Entertainment", "ACT-CC", -60),
            ("Amazon.com", -3_120, "Shopping", "ACT-CC", -66),
            ("Payroll Deposit", 512_500, "Income", "ACT-CHK", -67),
            ("Electric Bill", -9_800, "Utilities", "ACT-CHK", -72),
        ]

        let accounts = ["ACT-CHK": checking, "ACT-SAV": savings, "ACT-CC": card]
        var seenMerchants: Set<String> = []
        for (index, sample) in samples.enumerated() {
            guard let account = accounts[sample.3] else { continue }
            let transaction = LedgerTransaction(
                bankTransactionID: "TXN-\(index)-\(sample.3)",
                payeeDescription: sample.0,
                amountMinorUnits: sample.1
            )
            transaction.account = account
            transaction.accountIDIndex = account.bankAccountID
            transaction.currencyExponent = 2
            transaction.postedDate = calendar.date(byAdding: .day, value: sample.4, to: now)
            transaction.isPending = index % 11 == 0
            transaction.createdAt = transaction.effectiveDate
            transaction.modifiedAt = transaction.createdAt
            transaction.normalizedMerchant = MerchantNormalizer.normalize(sample.0)
            // The person's first transaction with a merchant stands in for a
            // manual correction; repeats are left uncategorized so the automatic
            // pass can recognize them from merchant memory.
            if seenMerchants.insert(sample.0).inserted {
                transaction.userCategory = category(sample.2)
            }
            context.insert(transaction)
        }

        // One merchant with no prior history or rule, so the on-device model has
        // something to categorize.
        let unique = LedgerTransaction(
            bankTransactionID: "TXN-UNCAT-1",
            payeeDescription: "Chevron Gas #4471",
            amountMinorUnits: -4_210
        )
        unique.account = card
        unique.accountIDIndex = card.bankAccountID
        unique.currencyExponent = 2
        unique.postedDate = calendar.date(byAdding: .day, value: -4, to: now)
        unique.createdAt = unique.effectiveDate
        unique.modifiedAt = unique.createdAt
        unique.normalizedMerchant = MerchantNormalizer.normalize("Chevron Gas #4471")
        context.insert(unique)

        // Money movement and a genuine charge, to exercise the deterministic
        // hints: the two money-movement rows become transfers (no category) and
        // the explicit fee is categorized as Fees — none of them hit the model.
        let hinted: [(String, Int64)] = [
            ("Zelle payment to Alex Morgan", -45_000),
            ("Overdraft to checking", 50_000),
            ("Overdraft fee", -3_500),
        ]
        for (index, item) in hinted.enumerated() {
            let transaction = LedgerTransaction(
                bankTransactionID: "TXN-HINT-\(index)",
                payeeDescription: item.0,
                amountMinorUnits: item.1
            )
            transaction.account = checking
            transaction.accountIDIndex = checking.bankAccountID
            transaction.currencyExponent = 2
            transaction.postedDate = calendar.date(byAdding: .day, value: -3, to: now)
            transaction.createdAt = transaction.effectiveDate
            transaction.modifiedAt = transaction.createdAt
            transaction.normalizedMerchant = MerchantNormalizer.normalize(item.0)
            context.insert(transaction)
        }

        try? context.save()
    }

    /// Creates one sample position. `cost` is the total cost basis; both values
    /// are in the position's currency (USD unless stated otherwise).
    // swiftlint:disable:next function_parameter_count
    private static func insertHolding(
        into account: Account,
        id: String,
        symbol: String,
        name: String,
        shares: String,
        market: Int64,
        cost: Int64,
        order: Int,
        currency: Currency = .usd,
        context: ModelContext
    ) {
        let holding = Holding(holdingID: id, name: name, currency: currency)
        holding.symbol = symbol
        holding.sharesRaw = shares
        holding.marketValueMinorUnits = market
        holding.costBasisMinorUnits = cost
        holding.hasCostBasis = true
        holding.displayOrder = order
        holding.account = account
        context.insert(holding)
    }
}
#endif
