import Foundation

// UIKit's alert helper has no presenter while the app is in the background.
final class Presenter {}
var presenter: Presenter?
func getTopViewController() -> Presenter? { presenter }
final class UIAlertAction {
    enum Style { case cancel, `default` }
    let title: String
    let handler: (UIAlertAction) -> Void
    init(title: String, style: Style, handler: @escaping (UIAlertAction) -> Void) {
        self.title = title
        self.handler = handler
    }
}
var offeredActions: [UIAlertAction] = []
func showAlert(_ title: String, message: String, actions: () -> [UIAlertAction]) {
    if getTopViewController() != nil { offeredActions = actions() }
}

@main struct InviteRetryTests {
    @MainActor static func main() async {
        var result = "pending"
        func request() async {
            showRetryAlert(("Connection timeout", "test"),
                           onCancel: { result = "cancelled" },
                           onRetry: { result = "retry" })
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        await request()
        guard result == "cancelled" && offeredActions.isEmpty else {
            print("FAIL: a background timeout must release the pending connection")
            exit(1)
        }
        presenter = Presenter()
        result = "pending"
        await request()
        guard result == "pending", offeredActions.count == 2 else { exit(1) }
        offeredActions[1].handler(offeredActions[1])
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while result == "pending" && ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
        guard result == "retry" else { exit(1) }
        await request()
        offeredActions[0].handler(offeredActions[0])
        guard result == "cancelled" else { exit(1) }
        print("Passed background timeout, foreground retry and cancellation")
    }
}
