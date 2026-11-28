import Foundation

enum TestSendError { case expired, relay, quota }
enum Status {
    case sndNew, sndSent, sndRcvd, sndErrorAuth, sndError(TestSendError), sndWarning(TestSendError)
    case rcvNew, rcvRead, invalid
}

final class XauXatConnectionRecoveryManager {
    static let shared = XauXatConnectionRecoveryManager()
    func setOutboundPending(_ pending: Bool) {}
}

private var expireGrant: (() -> Void)?
private var grantsReleased = 0

func beginTrackedBGTask(name: String, onFinish: @escaping (Bool) -> Void) -> () -> Void {
    var finished = false
    func finish(expired: Bool) {
        guard !finished else { return }
        finished = true
        grantsReleased += 1
        onFinish(expired)
    }
    expireGrant = { finish(expired: true) }
    return { finish(expired: false) }
}

@main enum OutboundWarningTests {
    static func main() {
        let delivery = OutboundDeliveryManager.shared
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            print("\(value ? "PASS" : "FAIL") \(message)")
            if !value { failures += 1 }
        }

        let send = delivery.beginSend()
        delivery.register(send, itemIds: [1])
        handle(1, .sndNew)
        handle(1, .sndWarning(.relay))
        check(delivery.pendingMessageCount == 1 && grantsReleased == 0, "relay warning keeps the retryable delivery")
        expireGrant?()
        check(delivery.pendingMessageCount == 1 && grantsReleased == 1, "iOS grant expiry releases execution time while the core retries")
        handle(1, .sndSent)
        check(delivery.pendingMessageCount == 0 && grantsReleased == 1, "sent ends tracking after the grant expired")

        let earlyWarning = delivery.beginSend()
        handle(2, .sndWarning(.quota))
        delivery.register(earlyWarning, itemIds: [2])
        check(delivery.pendingMessageCount == 1, "quota warning before API registration preserves pending work")
        handle(2, .sndError(.expired))
        check(delivery.pendingMessageCount == 0 && grantsReleased == 2, "native terminal expiry ends tracking and releases the grant")

        let batch = delivery.beginSend()
        delivery.register(batch, itemIds: [3, 4])
        handle(3, .sndWarning(.relay))
        handle(4, .sndErrorAuth)
        check(delivery.pendingMessageCount == 1 && grantsReleased == 2, "a terminal sibling does not end the pending batch")
        handle(3, .sndRcvd)
        check(delivery.pendingMessageCount == 0 && grantsReleased == 3, "receipt ends tracking even when sent was skipped")
        if failures > 0 { exit(1) }
    }
}
