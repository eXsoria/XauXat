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
    private func preview(canResume: Bool = true) {
        let phase = app.staticTexts["voice.phase"]
        let send = app.buttons["voice.send"]
        let recordingError = app.staticTexts["voice.error"]
        // Joining resumed AAC segments can take longer on a loaded simulator.
        // Require the actual completed preview, retaining every audio assertion.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            phase.exists && phase.label == "Phase preview" && send.exists && send.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed,
                       "Preview did not finish: \(phase.label); \(recordingError.label)")
        if canResume {
            XCTAssertTrue(app.buttons["voice.resume"].isHittable)
        } else {
            XCTAssertFalse(app.buttons["voice.resume"].exists, "The completed recorder cannot resume past the limit")
        }
        XCTAssertTrue(app.buttons["voice.delete"].isHittable)
        XCTAssertFalse(app.staticTexts["Playable 0.00"].exists, "A paused recording must already be playable")
        XCTAssertTrue(app.staticTexts["Sent 0"].exists, "Releasing must never send")
    }
    private func lockAndCaptureAudio(timeout: TimeInterval = 30) {
        let origin = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -120)))
        let captured = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let phase = self.app.staticTexts["voice.phase"]
            let duration = self.app.staticTexts["voice.duration"]
            return phase.exists && phase.label == "Phase locked" && duration.exists
                && (Double(duration.label.split(separator: " ").last ?? "0") ?? 0) >= 1.5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [captured], timeout: timeout), .completed,
                       "An explicit hands-free recording must capture real media before pausing")
    }
    private func assertRecordingKeepsConversationInPlace(withKeyboard: Bool) {
        app.launchArguments.append("chat-layout")
        openRecorder()
        let editor = app.textViews.firstMatch
        let keyboard = app.keyboards.firstMatch
        if withKeyboard {
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            editor.tap()
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        } else {
            XCTAssertFalse(keyboard.exists)
        }
        let message = app.staticTexts["chat.message.0"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        let messageFrame = message.frame
        let microphoneFrame = mic.frame
        let keyboardFrame = withKeyboard ? keyboard.frame : .zero
        let origin = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -120)))
        XCTAssertTrue(app.staticTexts["Phase locked"].waitForExistence(timeout: 5))
        XCTAssertEqual(keyboard.exists, withKeyboard, "Starting recording must preserve the keyboard state")
        if withKeyboard {
            XCTAssertEqual(keyboard.frame.minY, keyboardFrame.minY, accuracy: 1)
            app.typeText("ignored during recording")
            XCTAssertTrue(app.staticTexts["Phase locked"].exists, "Hidden text input must not replace the recording controls")
        }
        XCTAssertEqual(mic.frame.minY, microphoneFrame.minY, accuracy: 1, "The microphone must stay under the original touch")
        XCTAssertEqual(message.frame.minY, messageFrame.minY, accuracy: 1, "Recording must not move the conversation")
        XCTAssertTrue(app.staticTexts["Sent 0"].exists)
        snapshot(withKeyboard ? "recording-keyboard-and-chat-stable" : "recording-chat-stable")
        app.buttons["voice.cancel"].tap()
        XCTAssertTrue(app.staticTexts["Phase idle"].waitForExistence(timeout: 5))
        XCTAssertEqual(keyboard.exists, withKeyboard)
        XCTAssertEqual(message.frame.minY, messageFrame.minY, accuracy: 1)
        if withKeyboard {
            app.typeText("still focused")
            XCTAssertEqual(editor.value as? String, "still focused", "Cancelling restores the same focused editor")
        }
    }
    func testRecordingKeepsKeyboardAndConversationInPlace() {
        assertRecordingKeepsConversationInPlace(withKeyboard: true)
    }
    func testRecordingKeepsConversationInPlaceWithoutKeyboard() {
        assertRecordingKeepsConversationInPlace(withKeyboard: false)
    }
    func testStartingMicrophoneClosesPlayingSoundboard() {
        openRecorder()
        app.buttons["voice.expressions"].tap()
        app.buttons["Soundboard"].tap()
        XCTAssertTrue(app.buttons["Preview Ta-da"].waitForExistence(timeout: 5))
        app.buttons["Preview Ta-da"].tap()
        // The tray must close while capture continues. Measure captured media
        // after locking, rather than assuming audio preparation fits in a hold.
        lockAndCaptureAudio()
        XCTAssertFalse(app.buttons["Preview Ta-da"].exists, "Recording must close the soundboard")
        mic.tap()
        preview()
        let duration = Double(app.staticTexts["voice.playable"].label.split(separator: " ").last!)!
        XCTAssertGreaterThan(duration, 1, "Closing a playing tray cannot stop the microphone session")
    }

    func testHoldReleasePreviewResumeAndSend() {
        openRecorder()
        // Exercise a cold recording through the real UI, then discard it. The
        // measured hold below checks gestures after capture is available; it
        // does not impose a five-second deadline on cold simulator preparation.
        lockAndCaptureAudio(timeout: 60)
        mic.tap()
        preview()
        let coldFileDuration = Double(app.staticTexts["voice.playable"].label.split(separator: " ").last!)!
        XCTAssertGreaterThan(coldFileDuration, 1, "Cold preparation must produce playable AAC")
        app.buttons["voice.delete"].tap()
        XCTAssertTrue(app.staticTexts["Phase idle"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Sent 0"].exists)
        XCTAssertFalse(app.buttons["voice.send"].exists)
        XCTAssertTrue(app.staticTexts["Playable 0.00"].exists,
                      "Discarded preparation audio cannot supply the measured clip's duration")
        let record = mic
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            record.exists && record.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 10), .completed)
        // Retain the actual physical hold/release and every preview/append check.
        record.press(forDuration: 5)
        preview()
        snapshot("released-recording-preview")
        let firstFileDuration = Double(app.staticTexts["voice.playable"].label.split(separator: " ").last!)!
        XCTAssertGreaterThan(firstFileDuration, 0.5, "The first hold must capture playable audio before testing resume")
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
        preview(canResume: false)
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
        preview(canResume: false)
        let duration = Double(app.staticTexts["voice.playable"].label.split(separator: " ").last!)!
        XCTAssertEqual(duration, 6, accuracy: 0.3, "Pausing cannot reset the total recording limit")
    }
    func testPermissionGrantedAfterFingerReleasedDoesNotStartRecording() {
        app.resetAuthorizationStatus(for: .microphone)
        openRecorder()
        mic.press(forDuration: 0.2)
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        // A released tap may cancel before the startup Task asks the OS. If
        // the real prompt appears, grant only after the finger has lifted.
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        XCTAssertTrue(app.staticTexts["Phase idle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["voice.send"].exists)
        XCTAssertTrue(app.staticTexts["Duration 0.00"].exists)
        XCTAssertTrue(app.staticTexts["Playable 0.00"].exists)
        XCTAssertTrue(app.staticTexts["Sent 0"].exists)

        let origin = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -120)))
        // The new intent can be the first one to request permission. Observe
        // the real prompt or actual capture; never retry a timeout or failure.
        let permissionOrCapture = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            allow.exists || (self.app.staticTexts["Phase locked"].exists
                && (Double(self.app.staticTexts["voice.duration"].label.split(separator: " ").last ?? "0") ?? 0) >= 1.5)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [permissionOrCapture], timeout: 60), .completed)
        if allow.exists {
            allow.tap()
            // Presenting the OS prompt may cancel the held touch before its
            // slide-up locks. Only that empty, observed cancellation warrants
            // a new intentional gesture after permission has been granted.
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.app.staticTexts["Phase idle"].exists || self.app.staticTexts["Phase locked"].exists
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
            if app.staticTexts["Phase idle"].exists {
                XCTAssertTrue(app.staticTexts["Duration 0.00"].exists)
                XCTAssertTrue(app.staticTexts["Playable 0.00"].exists)
                XCTAssertTrue(app.staticTexts["Sent 0"].exists)
                XCTAssertFalse(app.buttons["voice.send"].exists)
                origin.press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -120)))
            }
        }
        let captured = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.staticTexts["Phase locked"].exists
                && (Double(self.app.staticTexts["voice.duration"].label.split(separator: " ").last ?? "0") ?? 0) >= 1.5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [captured], timeout: 60), .completed)
        mic.tap()
        preview()
        XCTAssertGreaterThan(Double(app.staticTexts["voice.playable"].label.split(separator: " ").last!)!, 1)
    }
}
