import XCTest

/// Runs against in-memory synthetic data. No bank credentials or persistent
/// user records are read or written by these UI tests.
final class PersonalTrackingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFlowNavigationAndInteractiveCharts() {
        let app = launchSampleApp()
        defer { app.terminate() }

        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.tabBars.buttons.count, 4)
        let spending = app.otherElements["todaySpendingChart"].firstMatch
        XCTAssertTrue(spending.waitForExistence(timeout: 10))
        reveal(spending, in: app)
        let spendingAmount = app.staticTexts["spendingHeadlineAmount"]
        spending.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let currentSpending = spendingAmount.label
        scrub(spending, to: 0.28)
        XCTAssertNotEqual(spendingAmount.label, currentSpending)
        capture("Flow Today spending", app: app)
        let chartTop = spending.frame.minY
        spending.swipeUp(velocity: .slow)
        XCTAssertLessThan(spending.frame.minY, chartTop - 15, "A vertical chart swipe should scroll the page")

        let netWorth = app.buttons["netWorthDetails"]
        let overviewHistory = app.otherElements["netWorthChart"].firstMatch
        reveal(overviewHistory, in: app)
        let currentOverview = netWorth.label
        scrub(overviewHistory, to: 0.28)
        XCTAssertNotEqual(netWorth.label, currentOverview, "Scrubbing should update the net-worth headline")
        capture("Flow Today net worth selection", app: app)
        open(netWorth, in: app)
        XCTAssertTrue(app.navigationBars["Net Worth"].waitForExistence(timeout: 5))
        let history = app.otherElements["netWorthHistoryChart"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        let netWorthAmount = app.staticTexts["netWorthHistoryAmount"]
        let currentNetWorth = netWorthAmount.label
        scrub(history, to: 0.28)
        XCTAssertNotEqual(netWorthAmount.label, currentNetWorth)
        capture("Flow net worth history", app: app)
        app.navigationBars.buttons.firstMatch.tap()

        open(app.buttons["spendingDetails"], in: app)
        XCTAssertTrue(app.navigationBars["Spending"].waitForExistence(timeout: 5))
        let monthPicker = app.buttons["Select month"]
        XCTAssertTrue(monthPicker.waitForExistence(timeout: 5))
        let currentMonth = monthPicker.value as? String
        XCTAssertNotNil(currentMonth)
        XCTAssertFalse(app.buttons["Next month"].isEnabled)
        capture("Flow Spending overview", app: app)
        app.buttons["Previous month"].tap()
        XCTAssertNotEqual(monthPicker.value as? String, currentMonth)
        app.buttons["Next month"].tap()
        XCTAssertEqual(monthPicker.value as? String, currentMonth)
        XCTAssertFalse(app.buttons["Next month"].isEnabled)

        let pace = app.otherElements["spendingPaceChart"].firstMatch
        reveal(pace, in: app)
        let detailAmount = app.staticTexts["spendingDetailHeadlineAmount"]
        let currentDetailAmount = detailAmount.label
        scrub(pace, to: 0.28)
        XCTAssertNotEqual(detailAmount.label, currentDetailAmount)
        capture("Flow spending line chart", app: app)
        let donut = app.otherElements["expenseBreakdownChart"].firstMatch
        reveal(donut, in: app)
        let initialValue = donut.value as? String
        donut.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.28)).tap()
        XCTAssertNotEqual(donut.value as? String, initialValue)
        capture("Flow expense donut selection", app: app)
        app.navigationBars.buttons.firstMatch.tap()

        selectTab("Wealth", in: app)
        XCTAssertTrue(app.navigationBars["Wealth"].waitForExistence(timeout: 5))
        capture("Flow Wealth", app: app)
        open(app.buttons["investmentDetails"], in: app)
        XCTAssertTrue(app.navigationBars["Investments"].waitForExistence(timeout: 5))
        capture("Flow Investments", app: app)
        app.navigationBars.buttons.firstMatch.tap()

        selectTab("Plan", in: app)
        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 5))
        capture("Flow Plan", app: app)
        open(app.buttons["settingsEntry"], in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        selectTab("Activity", in: app)
        let reviewInbox = app.buttons["reviewInboxEntry"]
        XCTAssertTrue(reviewInbox.waitForExistence(timeout: 5))
        capture("Flow Activity", app: app)
        reviewInbox.tap()
        XCTAssertTrue(app.navigationBars["Review Inbox"].waitForExistence(timeout: 5))
        capture("Activity review inbox", app: app)
    }

    @MainActor
    func testReviewedDuplicateAccountsCanBeCombined() {
        let app = launchSampleApp(extraArguments: ["--cairn-sample-duplicate-accounts"])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["settingsEntry"].waitForExistence(timeout: 15))
        open(app.buttons["settingsEntry"], in: app)
        open(app.buttons["settings.duplicateAccounts"], in: app)
        XCTAssertTrue(app.navigationBars["Duplicate Accounts"].waitForExistence(timeout: 5))
        let combine = app.buttons["duplicateAccounts.combineCopies"].firstMatch
        open(combine, in: app)
        let confirm = app.buttons["duplicateAccounts.confirmCombine"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let cancel = app.buttons["Cancel"]
        if cancel.exists {
            cancel.tap()
        } else {
            // Native confirmation popovers dismiss when tapping outside.
            app.navigationBars["Duplicate Accounts"]
                .coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        }
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(combine.exists, "Cancelling keeps the account copies separate")
        open(combine, in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Combined 2 copies into one account."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No duplicate accounts found"].exists)
        XCTAssertFalse(combine.exists)
        capture("Duplicate accounts combined", app: app)
    }

    @MainActor
    func testStandaloneSharedExpenseAndPartialRepayment() {
        let app = launchSampleApp()
        defer { app.terminate() }
        app.tabBars.buttons["Plan"].tap()
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
        app.tabBars.buttons["Plan"].tap()
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
    private func launchSampleApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--cairn-sample-data", "-cairn-disable-cloudkit",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-cairn.tabOrder", "", "-cairn.hiddenTabs", "", "-cairn-tab", "home",
        ] + extraArguments
        app.launch()
        return app
    }

    @MainActor
    private func selectTab(_ title: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        if !tab.exists {
            // The native tab bar collapses while scrolling. Tapping its
            // selected tab expands the destination buttons again.
            app.tabBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
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
            let scroll: XCUIElement
            if editor.exists {
                scroll = editor
            } else if app.scrollViews.firstMatch.exists {
                scroll = app.scrollViews.firstMatch
            } else if app.collectionViews.firstMatch.exists {
                scroll = app.collectionViews.firstMatch
            } else {
                scroll = app.tables.firstMatch
            }
            XCTAssertTrue(scroll.exists, "The current screen needs a scrollable container")
            let top = max(scroll.frame.minY, app.frame.minY + 120)
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? keyboard.frame.minY : min(scroll.frame.maxY, app.frame.maxY - 100)
            let scrollingBack = element.exists && element.frame.midY < top
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let upper = top + (bottom - top) * 0.35
            let lower = top + (bottom - top) * 0.65
            // Scroll from the content margin so a chart or editable control
            // cannot turn this navigation gesture into a value selection.
            let scrollX = scroll.frame.minX + 8
            let start = origin.withOffset(CGVector(dx: scrollX, dy: scrollingBack ? upper : lower))
            let end = origin.withOffset(CGVector(dx: scrollX, dy: scrollingBack ? lower : upper))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        if !element.exists || !element.isHittable { print(app.debugDescription) }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func scrub(_ chart: XCUIElement, to fraction: CGFloat) {
        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let end = chart.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
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
