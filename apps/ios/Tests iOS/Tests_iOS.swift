//
//  Tests_iOS.swift
//  Tests iOS
//
//  Created by Evgeny Poberezkin on 17/01/2022.
//

import XCTest

class Tests_iOS: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use recording to get started writing UI tests.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }

    func testGroupAccessRulesApplyInDeterministicOrder() {
        let now = Date(timeIntervalSince1970: 1_000)
        let rules = XauXatGroupAccessRules(
            maxUses: 1,
            expiresAt: now.addingTimeInterval(-1),
            requiresCode: true,
            individualAccessCount: nil
        )
        let evaluator = XauXatGroupAccessRuleEvaluator(rules: rules)

        XCTAssertEqual(evaluator.claim(at: now, codeAccepted: false), .codeRequired)
        XCTAssertEqual(evaluator.claim(at: now, codeAccepted: true), .expired)
        evaluator.revoke()
        XCTAssertEqual(evaluator.claim(at: now, codeAccepted: false), .revoked)
    }

    func testGroupAccessConcurrentClaimsCannotExceedMaximum() {
        let rules = XauXatGroupAccessRules(maxUses: 5, expiresAt: nil, requiresCode: false, individualAccessCount: nil)
        let evaluator = XauXatGroupAccessRuleEvaluator(rules: rules)
        let resultLock = NSLock()
        var allowed = 0

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if case .allowed = evaluator.claim(codeAccepted: true) {
                resultLock.lock()
                allowed += 1
                resultLock.unlock()
            }
        }

        XCTAssertEqual(allowed, 5)
        XCTAssertEqual(evaluator.claim(codeAccepted: true), .exhausted)
    }

    func testGroupAccessExpiryRejectsClaims() {
        let deadline = Date(timeIntervalSince1970: 2_000)
        let rules = XauXatGroupAccessRules(maxUses: 3, expiresAt: deadline, requiresCode: false, individualAccessCount: nil)
        let evaluator = XauXatGroupAccessRuleEvaluator(rules: rules)

        XCTAssertEqual(evaluator.claim(at: deadline.addingTimeInterval(-1), codeAccepted: true), .allowed(use: 1))
        XCTAssertEqual(evaluator.claim(at: deadline, codeAccepted: true), .expired)
    }

    func testGroupAccessRevocationIsTerminal() {
        let rules = XauXatGroupAccessRules(maxUses: 3, expiresAt: nil, requiresCode: false, individualAccessCount: nil)
        let evaluator = XauXatGroupAccessRuleEvaluator(rules: rules)

        XCTAssertEqual(evaluator.claim(codeAccepted: true), .allowed(use: 1))
        evaluator.revoke()
        XCTAssertEqual(evaluator.claim(codeAccepted: true), .revoked)
    }

    func testGroupAccessEditorValidatesCombinedRulesAndSummaryHasNoSecret() {
        let now = Date(timeIntervalSince1970: 3_000)
        let rules = XauXatGroupAccessRules(
            maxUses: 1,
            expiresAt: now.addingTimeInterval(3_600),
            requiresCode: true,
            individualAccessCount: 4
        )

        XCTAssertNil(rules.validationError(availableCapacity: 4, at: now))
        XCTAssertEqual(rules.validationError(availableCapacity: 3, at: now), .insufficientCapacity(available: 3))
        XCTAssertTrue(rules.summary().contains("Code required"))
        XCTAssertFalse(rules.summary().contains("111111"))
    }

    func testPINAttemptPolicyLocksAfterThirdFailure() {
        let now = Date(timeIntervalSince1970: 10_000)
        var state = XauXatPINAttemptState()

        XCTAssertEqual(state.recordFailure(policy: .lock, now: now, uptime: 100), .retry(remainingAttempts: 2))
        XCTAssertEqual(state.recordFailure(policy: .lock, now: now, uptime: 101), .retry(remainingAttempts: 1))
        XCTAssertEqual(state.recordFailure(policy: .lock, now: now, uptime: 102), .locked(remaining: 3_600))
        XCTAssertEqual(state.failedAttempts, 3)
    }

    func testPINAttemptLockExpiresAndResetsCounter() {
        let now = Date(timeIntervalSince1970: 20_000)
        var state = XauXatPINAttemptState()
        _ = state.recordFailure(policy: .lock, now: now, uptime: 200)
        _ = state.recordFailure(policy: .lock, now: now, uptime: 201)
        _ = state.recordFailure(policy: .lock, now: now, uptime: 202)

        XCTAssertNil(state.lockRemaining(now: now.addingTimeInterval(3_601), uptime: 3_803))
        XCTAssertEqual(state.failedAttempts, 0)
        XCTAssertEqual(
            state.recordFailure(policy: .lock, now: now.addingTimeInterval(3_602), uptime: 3_804),
            .retry(remainingAttempts: 2)
        )
    }

    func testPINAttemptLockCannotBeBypassedByMovingClockBackwards() {
        let now = Date(timeIntervalSince1970: 30_000)
        var state = XauXatPINAttemptState()
        _ = state.recordFailure(policy: .lock, now: now, uptime: 500)
        _ = state.recordFailure(policy: .lock, now: now, uptime: 501)
        _ = state.recordFailure(policy: .lock, now: now, uptime: 502)

        let remaining = state.lockRemaining(now: now.addingTimeInterval(-7_200), uptime: 602)
        XCTAssertNotNil(remaining)
        XCTAssertEqual(remaining!, 3_500, accuracy: 0.001)
    }

    func testPINAttemptDestructionRequiresExplicitPolicy() {
        let now = Date(timeIntervalSince1970: 40_000)
        var lockedState = XauXatPINAttemptState()
        _ = lockedState.recordFailure(policy: .lock, now: now, uptime: 800)
        _ = lockedState.recordFailure(policy: .lock, now: now, uptime: 801)
        XCTAssertEqual(
            lockedState.recordFailure(policy: .lock, now: now, uptime: 802),
            .locked(remaining: 3_600)
        )

        var destructiveState = XauXatPINAttemptState()
        _ = destructiveState.recordFailure(policy: .destroy, now: now, uptime: 900)
        _ = destructiveState.recordFailure(policy: .destroy, now: now, uptime: 901)
        XCTAssertEqual(destructiveState.recordFailure(policy: .destroy, now: now, uptime: 902), .destroy)
        XCTAssertNotNil(destructiveState.lockRemaining(now: now, uptime: 902))
    }
}
