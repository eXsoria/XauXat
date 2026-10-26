import XCTest

final class VoiceRecordingTests: XCTestCase {
    var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }
    private var mic: XCUIElement { app.buttons["voice.record"] }
    private func openRecorder() {
        app.launch()
        XCTAssertTrue(mic.waitForExistence(timeout: 20), "The composer must be ready before sending a gesture")
    }
    private func snapshot(_ name: String) {
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = name
        proof.lifetime = .keepAlways
        add(proof)
    }
    private func preview() {
        XCTAssertTrue(app.buttons["voice.send"].waitForExistence(timeout: 20), app.staticTexts["voice.error"].label)
        XCTAssertTrue(app.buttons["voice.resume"].isHittable)
        XCTAssertTrue(app.buttons["voice.delete"].isHittable)
        XCTAssertFalse(app.staticTexts["Playable 0.00"].exists, "A paused recording must already be playable")
        XCTAssertTrue(app.staticTexts["Sent 0"].exists, "Releasing must never send")
    }
    func testHoldReleasePreviewResumeAndSend() {
        openRecorder()
        mic.press(forDuration: 2)
        preview()
        snapshot("released-recording-preview")
        let firstFileDuration = Double(app.staticTexts["voice.playable"].label.split(separator: " ").last!)!
        app.buttons["voice.play"].tap()
        let first = app.staticTexts["voice.duration"].label
        app.buttons["voice.resume"].tap()
        XCTAssertTrue(mic.waitForExistence(timeout: 3))
        sleep(1)
        mic.tap()
        preview()
        XCTAssertNotEqual(first, app.staticTexts["voice.duration"].label, "Resume must extend the same recording")
        let resumedFileDuration = Double(app.staticTexts["voice.playable"].label.split(separator: " ").last!)!
        XCTAssertGreaterThan(resumedFileDuration, firstFileDuration + 0.5, "Resume must append audio to the same AAC file")
        app.buttons["voice.send"].tap()
        XCTAssertTrue(app.staticTexts["Sent 1"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Playable 0.00"].exists, "Finalized AAC must be playable")
    }
    func testSlideLeftCancelsWithoutLeavingMicrophoneRunning() {
        openRecorder()
        let origin = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.7, thenDragTo: origin.withOffset(CGVector(dx: -140, dy: 0)))
        XCTAssertTrue(mic.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Phase idle"].exists)
        XCTAssertFalse(app.buttons["voice.send"].exists)
        mic.press(forDuration: 2)
        preview()
        app.buttons["voice.delete"].tap()
        XCTAssertTrue(app.staticTexts["Phase idle"].waitForExistence(timeout: 3))
    }
    func testSlideUpLocksAndPauseShowsPreview() {
        app.launchArguments += ["dark", "large-text"]
        openRecorder()
        let origin = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -120)))
        XCTAssertTrue(app.staticTexts["Phase locked"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["voice.send"].exists)
        snapshot("hands-free-dark-accessibility-text")
        mic.tap()
        preview()
        snapshot("preview-dark-accessibility-text")
    }
    func testBackgroundStopsLockedRecording() {
        openRecorder()
        let origin = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -120)))
        XCTAssertTrue(app.staticTexts["Phase locked"].waitForExistence(timeout: 3))
        XCUIDevice.shared.press(.home)
        app.activate()
        preview()
    }
    func testLockedRecordingCanBeDeleted() {
        openRecorder()
        let origin = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -120)))
        XCTAssertTrue(app.buttons["voice.cancel"].waitForExistence(timeout: 3))
        app.buttons["voice.cancel"].tap()
        XCTAssertTrue(app.staticTexts["Phase idle"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["voice.send"].exists)
    }
    func testDurationLimitEndsHandsFreeRecording() {
        app.launchArguments.append("short-limit")
        openRecorder()
        let origin = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.7, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -120)))
        // The limit is media time; hosted simulator accessibility queries can stall longer.
        XCTAssertTrue(app.buttons["voice.send"].waitForExistence(timeout: 30), app.staticTexts["voice.error"].label)
        XCTAssertFalse(app.buttons["voice.resume"].exists, "The completed recorder cannot resume past the limit")
        XCTAssertFalse(app.staticTexts["Playable 0.00"].exists)
        let duration = Double(app.staticTexts["voice.playable"].label.split(separator: " ").last!)!
        XCTAssertEqual(duration, 6, accuracy: 0.3, "Hands-free capture must stop at the recording limit")
        XCTAssertTrue(app.staticTexts["Sent 0"].exists)
    }
    func testQuickTapDoesNotKeepRecording() {
        openRecorder()
        mic.tap()
        XCTAssertTrue(app.staticTexts["Phase idle"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["voice.send"].exists)
        XCTAssertTrue(app.staticTexts["Sent 0"].exists)
    }
    func testResumedRecordingHonorsTheTotalDurationLimit() {
        app.launchArguments.append("short-limit")
        openRecorder()
        mic.press(forDuration: 2)
        preview()
        app.buttons["voice.resume"].tap()
        XCTAssertTrue(app.buttons["voice.send"].waitForExistence(timeout: 20), app.staticTexts["voice.error"].label)
        XCTAssertFalse(app.buttons["voice.resume"].exists)
        let duration = Double(app.staticTexts["voice.playable"].label.split(separator: " ").last!)!
        XCTAssertEqual(duration, 6, accuracy: 0.3, "Pausing cannot reset the total recording limit")
    }
    func testPermissionGrantedAfterFingerReleasedDoesNotStartRecording() {
        app.resetAuthorizationStatus(for: .microphone)
        openRecorder()
        mic.press(forDuration: 0.2)
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        allow.tap()
        XCTAssertTrue(app.staticTexts["Phase idle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["voice.send"].exists)
        mic.press(forDuration: 2)
        preview()
    }
}
