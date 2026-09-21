import Foundation
import Testing
@testable import CairnCore

@Suite("Minor units")
struct MinorUnitsTests {
    @Test("Parses two-decimal amounts exactly")
    func parsesTwoDecimals() {
        #expect(MinorUnits.parse("100.23", exponent: 2) == 10_023)
        #expect(MinorUnits.parse("-33293.43", exponent: 2) == -3_329_343)
        #expect(MinorUnits.parse("0.00", exponent: 2) == 0)
        #expect(MinorUnits.parse("5", exponent: 2) == 500)
        #expect(MinorUnits.parse("5.5", exponent: 2) == 550)
        #expect(MinorUnits.parse(".5", exponent: 2) == 50)
        #expect(MinorUnits.parse("+12.34", exponent: 2) == 1_234)
    }

    @Test("Handles zero-decimal currencies")
    func parsesZeroDecimal() {
        #expect(MinorUnits.parse("1200", exponent: 0) == 1200)
        #expect(MinorUnits.parse("-45", exponent: 0) == -45)
    }

    @Test("Rejects malformed input")
    func rejectsMalformed() {
        #expect(MinorUnits.parse("", exponent: 2) == nil)
        #expect(MinorUnits.parse("abc", exponent: 2) == nil)
        #expect(MinorUnits.parse("1.2.3", exponent: 2) == nil)
        #expect(MinorUnits.parse("$5.00", exponent: 2) == nil)
    }

    @Test("Truncates digits beyond the currency exponent")
    func truncatesExtraDigits() {
        #expect(MinorUnits.parse("1.239", exponent: 2) == 123)
    }

    @Test("Parses the locale's decimal separator")
    func parsesLocaleDecimalSeparator() {
        let german = Locale(identifier: "de_DE")
        #expect(MinorUnits.parse("12,34", exponent: 2, locale: german) == 1_234)
        #expect(MinorUnits.parse("-1250,00", exponent: 2, locale: german) == -125_000)
        #expect(MinorUnits.parse(",5", exponent: 2, locale: german) == 50)
        #expect(MinorUnits.parse("1,2,3", exponent: 2, locale: german) == nil)
    }

    @Test("Accepts a dot regardless of the locale")
    func dotFallbackInCommaLocale() {
        let german = Locale(identifier: "de_DE")
        #expect(MinorUnits.parse("12.34", exponent: 2, locale: german) == 1_234)
        #expect(MinorUnits.parse("-33293.43", exponent: 2, locale: german) == -3_329_343)
    }

    @Test("Round-trips through string")
    func roundTrips() {
        #expect(MinorUnits.string(10_023, exponent: 2) == "100.23")
        #expect(MinorUnits.string(-3_329_343, exponent: 2) == "-33293.43")
        #expect(MinorUnits.string(50, exponent: 2) == "0.50")
        #expect(MinorUnits.string(7, exponent: 0) == "7")
    }

    @Test("Parsing is the inverse of string formatting")
    func inverse() {
        for raw in ["100.23", "-33293.43", "0.00", "999999.99", "0.01"] {
            let units = MinorUnits.parse(raw, exponent: 2)
            #expect(units != nil)
            #expect(MinorUnits.string(units ?? 0, exponent: 2) == raw)
        }
    }
}

@Suite("Currency")
struct CurrencyTests {
    @Test("Classifies ISO and custom currencies")
    func classification() {
        #expect(Currency.simpleFIN("usd").code == "USD")
        #expect(Currency.simpleFIN("USD").isCustom == false)
        #expect(Currency.simpleFIN("https://example.com/miles").isCustom == true)
        #expect(Currency.simpleFIN("JPY").exponent == 0)
        #expect(Currency.simpleFIN("USD").exponent == 2)
    }
}

@Suite("Money formatting")
struct MoneyTests {
    @Test("Custom currencies use their abbreviation")
    func customCurrency() {
        let currency = Currency(code: "https://example.com/miles", isCustom: true, customAbbreviation: "mi")
        let money = Money(minorUnits: 12_345, currency: currency)
        #expect(money.decimal == Decimal(string: "123.45"))
        #expect(money.formatted(locale: Locale(identifier: "en_US")).contains("mi"))
    }
}
