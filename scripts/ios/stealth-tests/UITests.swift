import XCTest

final class StealthTests: XCTestCase {
    var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
        for preset in ["veil", "alloy", "hollow", "wisp", "stealth"] {
            XCTAssertTrue(app.buttons["call.voicePreset.\(preset)"].exists)
        }
        app.switches["call.voiceMask.enabled"].tap()
        choose("call.voicePreset.stealth")
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
        app.switches["call.voiceMask.enabled"].tap()
        choose("call.voicePreset.stealth")
        app.buttons["Done"].tap()
        expect("fixture.call", "Call stealth / off / off")
        open("Call effects")
        app.switches["call.voiceMask.enabled"].tap()
        app.buttons["Done"].tap()
        expect("fixture.call", "Call stealth / on / neural")
    }
    func testNormalVoiceNotesOfferStealth() {
        open("Voice note settings")
        app.switches["xauxat voice mask"].tap()
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
