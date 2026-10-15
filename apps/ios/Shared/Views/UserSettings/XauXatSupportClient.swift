import Foundation
import SimpleXChat

@MainActor
enum XauXatSupportClient {
    static var contactAddress: String? {
        xauXatSupportContactAddress(Bundle.main.object(forInfoDictionaryKey: "XauXatSupportContactB64") as? String)
    }

    static var canConnect: Bool {
        ChatModel.shared.chatRunning == true && contactAddress != nil
    }

    static func openConversation(theme: AppTheme) {
        guard canConnect, let contactAddress else { return }
        // Use the same profile/incognito choice, Tor transport, link validation,
        // reconnect handling and existing-chat navigation as every other contact.
        // Opening this address never sends a report or copies selected content.
        planAndConnect(contactAddress, theme: theme, dismiss: true)
    }
}
