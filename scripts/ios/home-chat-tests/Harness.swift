import SwiftUI

// Native core and account services are adapters. The destination, swipe gesture,
// row, options sheet, confirmations and error presentation are production views.
typealias ChatId = String
enum ContactStatus { case active, deleted, deletedByUser }
struct Contact {
    var contactStatus: ContactStatus
    var active: Bool { contactStatus == .active }
    var isContactCard = false
}
enum ChatInfo {
    case direct(Contact), group, local, contactConnection
    var chatViewName: String { "Test contact" }
    var shortDescr: String? { nil }
    var chatTs: Date { Date(timeIntervalSince1970: 1_800_000_000) }
    var nextNtfMode: NtfMode? { nil }
    var hasMentions: Bool { false }
    var isChannel: Bool { false }
}
struct NtfMode {
    var icon: String { "bell" }
    func text(mentions: Bool) -> String { "Notifications" }
}
struct ChatItem {
    struct Meta { var itemTs: Date }
    var meta = Meta(itemTs: Date(timeIntervalSince1970: 1_800_000_000))
    func text(isChannel: Bool) -> String { "deleted contact" }
}
struct ChatStats { var unreadCount = 0 }
final class Chat: ObservableObject, Identifiable {
    let id = "@7"
    @Published var chatInfo: ChatInfo
    var chatItems = [ChatItem()]
    var chatStats = ChatStats()
    init(_ status: ContactStatus) { chatInfo = .direct(Contact(contactStatus: status)) }
}
enum ChatDeleteMode { case full(notify: Bool), messages }
final class ChatModel: ObservableObject {
    static let shared = ChatModel()
    var chatRunning: Bool? = true
    var deletedChats = Set<String>()
    @Published var chats: [Chat] = []
    @Published var result = "No deletion"
    @Published var opens = 0
    var failOnce = false
}
final class ItemsModel {
    static let shared = ItemsModel()
    func loadOpenChat(_ id: String) { ChatModel.shared.opens += 1 }
}
final class XauXatPlusEntitlements: ObservableObject {
    enum Feature { case conversationLock }
    func isAuthorized(for feature: Feature) -> Bool { true }
}
struct XauXatPlusView: View { var body: some View { Text("Plus") } }
struct SomeAlert: Identifiable { var alert: Alert; var id: String }
struct SomeSheet<Content: View>: Identifiable {
    @ViewBuilder var content: Content
    var id: String
    var fraction = 0.4
}
struct ChatListNavLink: View {
    var chat: Chat
    @Binding var parentSheet: SomeSheet<AnyView>?
    var body: some View {
        Text("Legacy row").accessibilityIdentifier("legacy.row")
            .swipeActions { Button("Legacy delete") {} }
    }
}
struct ChatInfoImage: View {
    var chat: Chat
    var size: CGFloat
    var color: Color
    var radiusOverride: CGFloat?
    var body: some View {
        Image(systemName: "person.circle.fill").resizable()
            .frame(width: size, height: size).foregroundColor(color)
    }
}
func formatTimestampText(_ date: Date) -> Text { Text("16:18") }
func chatPreviewText(_ chat: Chat) -> String {
    if case let .direct(contact) = chat.chatInfo, !contact.active { return "deleted contact" }
    return "Message preview"
}
func xauXatIsChatLocked(_ id: String) -> Bool { false }
func xauXatSetChatLocked(_ id: String, locked: Bool) -> Bool { true }
func toggleNotifications(_ chat: Chat, enableNtfs: NtfMode) {}
func authenticate(title: String, reason: String, completion: (Result<Void, Error>) -> Void) {
    completion(.success(()))
}
extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

@MainActor
func deleteContactChat(_ chat: Chat, chatDeleteMode: ChatDeleteMode) async -> Alert? {
    let m = ChatModel.shared
    if m.failOnce {
        m.failOnce = false
        return Alert(title: Text("Error deleting chat!"), message: Text("Local store unavailable"))
    }
    switch chatDeleteMode {
    case let .full(notify):
        m.result = "Full deletion notify=\(notify)"
        UserDefaults.standard.set(true, forKey: "fixture.deleted")
    case .messages:
        m.result = "Messages deleted; contact retained"
    }
    m.chats.removeAll { $0.id == chat.id }
    return nil
}

@main struct HomeChatHarness: App {
    @StateObject private var model = ChatModel.shared
    @StateObject private var entitlements = XauXatPlusEntitlements()
    @State private var parentSheet: SomeSheet<AnyView>?
    @State private var swiping = false

    init() {
        let args = ProcessInfo.processInfo.arguments
        let status: ContactStatus = args.contains("deleted-by-user") ? .deletedByUser
            : args.contains("active") ? .active : .deleted
        if !args.contains("preserve-store") {
            UserDefaults.standard.removeObject(forKey: "fixture.deleted")
        }
        ChatModel.shared.chats = UserDefaults.standard.bool(forKey: "fixture.deleted") ? [] : [Chat(status)]
        ChatModel.shared.failOnce = args.contains("fail-once")
        ChatModel.shared.result = "No deletion"
        ChatModel.shared.opens = 0
    }

    var body: some Scene {
        WindowGroup {
            VStack {
                Text("Chats").font(.largeTitle)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.chats) { chat in
                            XauXatChatDestination(chat: chat, palette: XauXatPalette(.light),
                                parentSheet: $parentSheet, contactStyle: false, chatSwipeActive: $swiping)
                        }
                    }.padding(.horizontal, 22)
                }
                Text(model.result).accessibilityIdentifier("delete.result")
                Text("Opened \(model.opens)").accessibilityIdentifier("open.result")
                Button("Receive deletion event") {
                    model.chats.first?.chatInfo = .direct(Contact(contactStatus: .deleted))
                }
            }
            .background(XauXatPalette(.light).background)
            .environmentObject(model).environmentObject(entitlements)
        }
    }
}
