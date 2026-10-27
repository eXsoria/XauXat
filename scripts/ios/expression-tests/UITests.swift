import XCTest

final class ExpressionUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["validation"].waitForExistence(timeout: 20))
        let ready = NSPredicate(format: "label == 'Ready' OR label BEGINSWITH 'FAILED:'")
        expectation(for: ready, evaluatedWith: app.staticTexts["validation"])
        waitForExpectations(timeout: 30)
        XCTAssertEqual(app.staticTexts["validation"].label, "Ready")
        XCTAssertTrue(app.buttons[arguments.contains("--limited") ? "Choose sound Pop" : "Send sticker 👍"].waitForExistence(timeout: 10))
        return app
    }

    func proof(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPrivacyProperties() {
        let app = XCUIApplication()
        app.launchArguments = ["--privacy"]
        app.launch()
        XCTAssertTrue(app.staticTexts["validation"].waitForExistence(timeout: 20))
        let ready = NSPredicate(format: "label BEGINSWITH 'Privacy checks passed:' OR label BEGINSWITH 'FAILED:'")
        expectation(for: ready, evaluatedWith: app.staticTexts["validation"])
        waitForExpectations(timeout: 30)
        XCTAssertTrue(app.staticTexts["validation"].label.hasPrefix("Privacy checks passed:"), app.staticTexts["validation"].label)
        proof(app, "privacy-checks")
    }

    func testStickerTrayRecentsAndFavorites() {
        let app = launch()
        proof(app, "sticker-tray")
        let sticker = app.buttons["Send sticker 👍"]
        sticker.press(forDuration: 1.2)
        app.buttons["Add to Favorites"].tap()
        app.buttons["Favorites"].tap()
        XCTAssertTrue(sticker.waitForExistence(timeout: 3))
        sticker.tap()
        XCTAssertEqual(app.staticTexts["selection"].label, "Sticker sent")
        XCTAssertTrue(app.staticTexts["Unsent draft stays here"].exists)
        app.buttons["Recents"].tap()
        XCTAssertTrue(sticker.exists)
    }

    func testSoundPreviewDoesNotSend() {
        let app = launch()
        app.buttons["Soundboard"].tap()
        let preview = app.buttons["Preview Pop"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        proof(app, "soundboard-tray")
        XCTAssertEqual(app.staticTexts["selection"].label, "Nothing sent")
        preview.tap()
        XCTAssertEqual(app.staticTexts["selection"].label, "Nothing sent")
        app.buttons["Choose sound Pop"].tap()
        XCTAssertEqual(app.staticTexts["selection"].label, "Sound ready to send")
    }

    func testLocalSearch() {
        let app = launch()
        let search = app.textFields["Search this device"]
        search.tap()
        search.typeText("no-match")
        XCTAssertFalse(app.buttons["Send sticker 👍"].exists)
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.buttons["Send sticker 👍"].waitForExistence(timeout: 3))
    }

    func testConversationPermissions() {
        let app = launch(["--limited"])
        app.buttons["Stickers"].tap()
        XCTAssertFalse(app.buttons["Send sticker 👍"].isEnabled)
        app.buttons["Soundboard"].tap()
        XCTAssertFalse(app.buttons["Preview Pop"].isEnabled)
        XCTAssertTrue(app.buttons["Choose sound Pop"].isEnabled)
    }

    func testLargeTextControlsRemainReachable() {
        let app = launch(["--large-text"])
        XCTAssertTrue(app.buttons["Close stickers and sounds"].isHittable)
        app.buttons["Soundboard"].tap()
        XCTAssertTrue(app.buttons["Choose sound Pop"].isHittable)
        proof(app, "soundboard-large-text")
        // XCTest scrolls this action into view in the keyboard-sized tray.
        app.buttons["Preview Pop"].tap()
        XCTAssertEqual(app.staticTexts["selection"].label, "Nothing sent")
    }
}
