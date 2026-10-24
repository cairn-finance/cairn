import XCTest

/// Runs against in-memory synthetic data. No bank credentials or persistent
/// user records are read or written by these UI tests.
final class PersonalTrackingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStandaloneSharedExpenseAndPartialRepayment() {
        let app = launchSampleApp()
        defer { app.terminate() }
        open(app.buttons["sharedExpensesEntry"], in: app)
        app.buttons["addSharedExpense"].tap()
        fill(app.textFields["Description"], with: "Simulator dinner", in: app)
        fill(app.textFields["Total amount"], with: "120", in: app)
        fill(app.textFields["Person's name"].firstMatch, with: "Riley", in: app)
        saveEditor("saveSharedExpense", in: app)

        let expense = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Simulator dinner")).firstMatch
        XCTAssertTrue(expense.waitForExistence(timeout: 10))
        open(expense, in: app)
        expectLabel("$60.00", on: app.staticTexts["sharedExpenseOutstanding"].firstMatch)
        capture("Shared expense without a bank transaction", app: app)

        open(app.buttons["recordSharedPayment"].firstMatch, in: app)
        fill(app.textFields["Payment amount"], with: "20", in: app)
        saveEditor(in: app)
        let outstanding = app.staticTexts["sharedExpenseOutstanding"].firstMatch
        expectLabel("$40.00", on: outstanding)
        capture("Shared expense after partial repayment", app: app)
    }

    @MainActor
    func testSinkingFundContributionAndWithdrawal() {
        let app = launchSampleApp()
        defer { app.terminate() }
        open(app.buttons["sinkingFundsEntry"], in: app)
        app.buttons["addSinkingFund"].tap()
        fill(app.textFields["Fund name"], with: "Simulator insurance", in: app)
        fill(app.textFields["Target amount"], with: "1200", in: app)
        fill(app.textFields["Already allocated (optional)"], with: "300", in: app)
        fill(app.textFields["Monthly contribution plan (optional)"], with: "100", in: app)
        saveEditor("saveSinkingFund", in: app)

        let fund = app.buttons["Simulator insurance"]
        XCTAssertTrue(fund.waitForExistence(timeout: 10))
        open(fund, in: app)
        let funded = app.staticTexts["fundedAmount"]
        expectLabel("$300.00", on: funded)
        capture("Sinking fund with opening allocation", app: app)

        open(app.buttons["recordFundAllocation"], in: app)
        fill(app.textFields["Amount"], with: "100", in: app)
        saveEditor(in: app)
        expectLabel("$400.00", on: funded)
        capture("Sinking fund after contribution", app: app)

        open(app.buttons["recordFundAllocation"], in: app)
        app.descendants(matching: .any)["fundEntryType"].firstMatch.tap()
        let withdrawal = app.descendants(matching: .any)["Withdrawal"].firstMatch
        XCTAssertTrue(withdrawal.waitForExistence(timeout: 5))
        withdrawal.tap()
        fill(app.textFields["Amount"], with: "50", in: app)
        saveEditor(in: app)
        expectLabel("$350.00", on: funded)
        capture("Sinking fund after withdrawal", app: app)
    }

    @MainActor
    private func launchSampleApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--cairn-sample-data", "-cairn-disable-cloudkit",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func open(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        element.tap()
    }

    @MainActor
    private func fill(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        reveal(field, in: app)
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
        field.typeText("\n")
    }

    @MainActor
    private func saveEditor(_ identifier: String = "Save", in app: XCUIApplication) {
        app.scrollViews["trackingEditorScroll"].swipeDown(velocity: .slow)
        let save = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ OR label == %@", identifier, "Save")
        ).firstMatch
        if !save.exists { print(app.debugDescription) }
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        _ = element.waitForExistence(timeout: 1)
        for _ in 0..<14 {
            if element.exists && element.isHittable { break }
            let editor = app.scrollViews["trackingEditorScroll"]
            let scroll = editor.exists ? editor : app.scrollViews.firstMatch
            let top = max(scroll.frame.minY, app.frame.minY + 120)
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? keyboard.frame.minY : min(scroll.frame.maxY, app.frame.maxY - 100)
            let scrollingBack = element.exists && element.frame.midY < top
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let upper = top + (bottom - top) * 0.35
            let lower = top + (bottom - top) * 0.65
            let start = origin.withOffset(CGVector(dx: scroll.frame.midX, dy: scrollingBack ? upper : lower))
            let end = origin.withOffset(CGVector(dx: scroll.frame.midX, dy: scrollingBack ? lower : upper))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        if !element.exists || !element.isHittable { print(app.debugDescription) }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func expectLabel(_ label: String, on element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
