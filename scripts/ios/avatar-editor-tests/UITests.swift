import XCTest

final class AvatarEditorTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    private func openCamera() {
        app.buttons["profile.camera"].tap()
        XCTAssertTrue(app.buttons["source.use"].waitForExistence(timeout: 5))
        app.buttons["source.use"].tap()
        assertControls()
    }

    private func assertControls(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.buttons["avatar.confirm"].waitForExistence(timeout: 8), file: file, line: line)
        XCTAssertTrue(app.buttons["avatar.confirm"].isHittable, file: file, line: line)
        XCTAssertTrue(app.buttons["avatar.cancel"].isHittable, file: file, line: line)
        XCTAssertFalse(app.buttons["source.use"].exists, "The source picker must be gone", file: file, line: line)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCameraCanConfirmBeforeAnyDrag() {
        app.launch()
        openCamera()
        snapshot("camera-editor-before-drag")
        app.buttons["avatar.confirm"].tap()
        XCTAssertTrue(app.staticTexts["Saved 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["profile.avatar"].exists)
        snapshot("saved-camera-avatar")
        app.buttons["profile.camera"].tap()
        app.buttons["source.cancel"].tap()
        XCTAssertTrue(app.staticTexts["Saved 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["avatar.confirm"].exists)
    }

    func testDraggingAndZoomingCannotCoverExitControls() {
        app.launch()
        for _ in 0..<2 {
            openCamera()
            let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            middle.press(forDuration: 0.1, thenDragTo: top)
            app.pinch(withScale: 3, velocity: 1)
            assertControls()
            snapshot("dragged-and-zoomed-editor")
            app.buttons["avatar.cancel"].tap()
            XCTAssertTrue(app.buttons["profile.camera"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Saved 0"].exists)
        }
    }

    func testLibraryAndPasteCanConfirm() {
        app.launch()
        app.buttons["profile.library"].tap()
        app.buttons["source.use"].tap()
        assertControls()
        app.buttons["avatar.confirm"].tap()
        XCTAssertTrue(app.staticTexts["Saved 1"].waitForExistence(timeout: 5))
        app.buttons["profile.paste"].tap()
        assertControls()
        app.buttons["avatar.confirm"].tap()
        XCTAssertTrue(app.staticTexts["Saved 2"].waitForExistence(timeout: 5))
        app.buttons["profile.library"].tap()
        app.buttons["source.cancel"].tap()
        XCTAssertTrue(app.buttons["profile.library"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["avatar.confirm"].exists)
    }

    func testImageDeliveredAfterLibraryDismissal() {
        app.launch()
        app.buttons["profile.library"].tap()
        app.buttons["source.late"].tap()
        assertControls()
        app.buttons["avatar.cancel"].tap()
        XCTAssertTrue(app.staticTexts["Saved 0"].waitForExistence(timeout: 5))
    }

    func testExitControlsWithAccessibilityText() {
        app.launchArguments.append("large-text")
        app.launch()
        openCamera()
        snapshot("accessibility-text-editor")
        app.buttons["avatar.cancel"].tap()
        XCTAssertTrue(app.staticTexts["Saved 0"].waitForExistence(timeout: 5))
    }
}
