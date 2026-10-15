import SwiftUI
import SimpleXChat

struct XauXatSupportHomeView: View {
    var body: some View {
        XauXatSupportComposeView()
    }
}

// The compose screen is an explanation and connection entry point. Reports and
// replies are ordinary encrypted chat messages composed by the user afterwards.
struct XauXatSupportComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var chatModel = ChatModel.shared
    var report: XauXatSafetyReport? = nil

    var body: some View {
        List {
            if let report {
                Section(header: Text("Your report")) {
                    Text(report.reason)
                    Text("No report has been sent. Open the support conversation, describe what happened and choose what to share.")
                }
            }
            Section {
                Button {
                    XauXatSupportClient.openConversation(theme: theme)
                } label: {
                    Label("Contact XauXat support", systemImage: "bubble.left.and.bubble.right")
                }
                .disabled(chatModel.chatRunning != true || XauXatSupportClient.contactAddress == nil)
            } footer: {
                Text("Support and replies use an end-to-end encrypted conversation in this app. You can return to it from your chats.")
            }
            Section(header: Text("What you share")) {
                Text("The support team sees the profile name and image you choose when connecting, and the messages you send in that conversation.")
                Text("Opening support does not attach another contact's name, selected messages, files, chat history, keys or device tokens. Write your report in the conversation and send only the information you choose.")
                Text("Support cannot read your other conversations. Blocking a contact is a separate action and does not require a report.")
            }
            Section(header: Text("Group reports")) {
                Text("Reports made inside a group go to that group's moderators through the native reporting feature. They are not automatically sent to the XauXat team.")
            }
            Section(header: Text("Support privacy")) {
                Text("The support team can read what you send to support. Messages on the support profile are automatically deleted after 30 days; your own copy is managed by your app. Encrypted backups may retain messages for up to 7 additional days. Contact records remain until the conversation is deleted. Ask in the conversation to request deletion.")
                Text("Support is handled by a person. Do not send passwords, recovery keys or full chat histories. This is not an emergency service.")
            }
            if XauXatSupportClient.contactAddress == nil {
                Section { Text("The official support contact is not configured in this build.") }
            } else if chatModel.chatRunning != true {
                Section { Text("Start chat to connect to support.") }
            }
        }
        .navigationTitle(report?.title ?? "Support & safety")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if report != nil {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }
}
