import XCTest

final class StealthTests: XCTestCase {
    var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            snapshot("failure")
            print(app.debugDescription)
        }
    }
    func setToggle(_ identifier: String, enabled: Bool) {
        let control = app.switches[identifier]
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        if !control.isHittable { app.swipeDown() }
        let value = enabled ? "1" : "0"
        if control.value as? String != value {
            // SwiftUI's AX frame includes the row label; target the actual thumb.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }
    func open(_ button: String) {
        if app.state != .runningForeground { app.launch() }
        XCTAssertTrue(app.buttons[button].waitForExistence(timeout: 20))
        app.buttons[button].tap()
    }
    func choose(_ identifier: String) {
        let row = app.buttons[identifier]
        XCTAssertTrue(row.waitForExistence(timeout: 10), identifier)
        if !row.isHittable { app.swipeUp() }
        row.tap()
    }
    func expect(_ identifier: String, _ label: String, timeout: TimeInterval = 15) {
        let value = app.staticTexts[identifier]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", label), object: value)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, value.label)
    }
    func snapshot(_ name: String) {
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = name
        proof.lifetime = .keepAlways
        add(proof)
    }
    func testCallMenuKeepsAllPresetsAndSwitchesProcessing() {
        open("Call effects")
        for preset in ["veil", "alloy", "hollow", "wisp"] {
            XCTAssertTrue(app.buttons["call.voicePreset.\(preset)"].exists)
        }
        setToggle("call.stealth.enabled", enabled: true)
        snapshot("call-stealth-and-existing-presets")
        let ambience = app.descendants(matching: .any)["call.ambience"].firstMatch
        XCTAssertTrue(ambience.exists)
        if !ambience.isHittable { app.swipeUp() }
        ambience.tap()
        app.buttons["Rain"].tap()
        app.buttons["Done"].tap()
        expect("fixture.call", "Call stealth / on / neural")
        expect("fixture.ambience", "Ambience rain")
        for preset in ["veil", "alloy", "hollow", "wisp"] {
            open("Call effects")
            choose("call.voicePreset.\(preset)")
            app.buttons["Done"].tap()
            expect("fixture.call", "Call \(preset) / on / legacy")
            expect("fixture.ambience", "Ambience rain")
        }
        open("Call effects")
        setToggle("call.voiceMask.enabled", enabled: false)
        setToggle("call.stealth.enabled", enabled: true)
        app.buttons["Done"].tap()
        expect("fixture.call", "Call stealth / on / neural")
        open("Call effects")
        setToggle("call.stealth.enabled", enabled: false)
        app.buttons["Done"].tap()
        expect("fixture.call", "Call stealth / off / off")
        open("Call effects")
        setToggle("call.voiceMask.enabled", enabled: true)
        app.buttons["Done"].tap()
        expect("fixture.call", "Call veil / on / legacy")
    }
    func testFreeCallOffersStealth() {
        app.launchArguments.append("free")
        open("Call effects")
        XCTAssertFalse(app.switches["call.voiceMask.enabled"].exists)
        setToggle("call.stealth.enabled", enabled: true)
        app.buttons["Done"].tap()
        expect("fixture.call", "Call stealth / on / neural")
    }
    func testCallCanStartWithStealth() {
        app.launchArguments.append("start-stealth")
        app.launch()
        expect("fixture.call", "Call stealth / on / neural")
        expect("fixture.initialPath", "Initial path neural")
    }
    func testNormalVoiceNotesOfferStealth() {
        open("Voice note settings")
        setToggle("xauxat voice mask", enabled: true)
        let picker = app.descendants(matching: .any)["voice.note.preset"].firstMatch
        XCTAssertTrue(picker.exists)
        picker.tap()
        let stealth = app.buttons["Stealth"].firstMatch
        if stealth.exists { stealth.tap() } else { app.staticTexts["Stealth"].firstMatch.tap() }
        snapshot("normal-voice-note-stealth")
        app.buttons["Done"].tap()
        expect("fixture.note", "Voice note stealth")
    }
    func testFreeVoiceNotesOfferStealth() {
        app.launchArguments.append("free")
        testNormalVoiceNotesOfferStealth()
    }
    func testRecordingStealthRendersWithBundledModel() {
        open("Recording effects")
        choose("voice.recording.preset.stealth")
        snapshot("recording-stealth-option")
        app.buttons["Apply"].tap()
        expect("fixture.result", "Stealth verified · recording and 16/48 kHz capture", timeout: 90)
        snapshot("real-coreml-audio-verified")
    }
    func testMissingModelPreservesOriginalRecording() {
        app.launchArguments.append("expect-missing-model")
        open("Recording effects")
        choose("voice.recording.preset.stealth")
        app.buttons["Apply"].tap()
        expect("fixture.result", "Model missing · original preserved", timeout: 30)
    }
}
