import XCTest

final class HomeChatTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    private var row: XCUIElement { app.buttons["xauxat.chat.@7"] }
    private var result: XCUIElement { app.staticTexts["delete.result"] }

    private func action(_ title: String) -> XCUIElement {
        let buttons = app.buttons.matching(identifier: title)
        return buttons.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? buttons.firstMatch
    }

    private func waitUntil(_ condition: @escaping () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, file: file, line: line)
    }

    private func revealActions() {
        XCTAssertFalse(app.staticTexts["legacy.row"].exists, "Deleted contacts must use the ScrollView-compatible row")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        waitUntil { self.action("Delete").isHittable }
    }

    private func requestDeletion() {
        revealActions()
        action("Delete").tap()
        XCTAssertTrue(app.buttons["Delete chat"].waitForExistence(timeout: 3))
    }

    private func assertResult(_ expected: String) {
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5))
        XCTAssertEqual(result.label, expected)
    }

    private func proof(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRemoteDeletedContactCanBeCancelledRemovedAndStaysRemovedAfterRelaunch() {
        app.launch()
        requestDeletion()
        XCTAssertTrue(app.staticTexts["This contact and its conversation will be permanently deleted."].exists)
        proof("deleted-contact-confirmation")
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            // iOS can present confirmationDialog as a popover: its system
            // dismissal region replaces the explicit Cancel button.
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismissRegion.waitForExistence(timeout: 3))
            dismissRegion.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
        }
        waitUntil { !self.app.buttons["Delete chat"].exists }
        XCTAssertTrue(row.exists)
        XCTAssertEqual(result.label, "No deletion")
        requestDeletion()
        app.buttons["Delete chat"].tap()
        assertResult("Full deletion notify=false")
        XCTAssertFalse(row.exists)
        proof("deleted-contact-removed")
        app.terminate()
        app.launchArguments.append("preserve-store")
        app.launch()
        XCTAssertFalse(row.exists)
    }

    func testLocallyDeletedContactCanBeRemoved() {
        app.launchArguments.append("deleted-by-user")
        app.launch()
        requestDeletion()
        app.buttons["Delete chat"].tap()
        assertResult("Full deletion notify=false")
        XCTAssertFalse(row.exists)
    }

    func testFailedDeletionShowsErrorAndKeepsRowForRetry() {
        app.launchArguments.append("fail-once")
        app.launch()
        requestDeletion()
        app.buttons["Delete chat"].tap()
        XCTAssertTrue(app.alerts["Error deleting chat!"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Local store unavailable"].exists)
        proof("deletion-error-retains-contact")
        app.alerts.buttons.firstMatch.tap()
        waitUntil { !self.app.alerts.firstMatch.exists }
        XCTAssertTrue(row.exists)
        XCTAssertEqual(result.label, "No deletion")
        requestDeletion()
        app.buttons["Delete chat"].tap()
        assertResult("Full deletion notify=false")
    }

    func testActiveConversationDeletionStillRetainsContact() {
        app.launchArguments.append("active")
        app.launch()
        requestDeletion()
        XCTAssertTrue(app.staticTexts["The conversation will be deleted. The contact will remain in Contacts."].exists)
        app.buttons["Delete chat"].tap()
        assertResult("Messages deleted; contact retained")
    }

    func testMoreMenuRemovesInactiveContactWithoutNotification() {
        app.launch()
        revealActions()
        action("More").tap()
        XCTAssertTrue(app.buttons["Delete contact"].waitForExistence(timeout: 3))
        app.buttons["Delete contact"].tap()
        XCTAssertTrue(app.staticTexts["This contact and its conversation will be permanently deleted."].waitForExistence(timeout: 5))
        app.buttons["Delete contact"].tap()
        assertResult("Full deletion notify=false")
    }

    func testMoreMenuDeletesActiveContactWithNotification() {
        app.launchArguments.append("active")
        app.launch()
        revealActions()
        action("More").tap()
        XCTAssertTrue(app.buttons["Delete contact"].waitForExistence(timeout: 3))
        app.buttons["Delete contact"].tap()
        XCTAssertTrue(app.staticTexts["This contact and its conversation will be permanently deleted."].waitForExistence(timeout: 5))
        app.buttons["Delete contact"].tap()
        assertResult("Full deletion notify=true")
    }

    func testReceivedDeletionKeepsSwipeAvailableWithoutDeletingAutomatically() {
        app.launchArguments.append("active")
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.buttons["Receive deletion event"].tap()
        XCTAssertEqual(result.label, "No deletion")
        requestDeletion()
        app.buttons["Delete chat"].tap()
        assertResult("Full deletion notify=false")
    }
}
