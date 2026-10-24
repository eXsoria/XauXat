import Foundation

// Store, UIKit and model adapters. Both the request/retry function and the
// complete pagination/merge implementation are extracted from production.
typealias ChatId = String
enum ChatType { case direct, group }
enum MsgContentTag { case image }
enum GroupChatScope {}
struct GroupScopeInfo { func toChatScope() -> GroupChatScope? { nil } }
enum ChatPagination {
    case initial(count: Int), last(count: Int), before(chatItemId: Int64, count: Int)
    case after(chatItemId: Int64, count: Int), around(chatItemId: Int64, count: Int)
}
struct ChatItem: Equatable {
    typealias ID = Int64
    struct Meta: Equatable {
        var itemId: Int64
        var itemTs = Date()
        var createdAt = Date()
    }
    var id: Int64
    var isRcvNew = false
    var meta: Meta { Meta(itemId: id) }
}
struct ChatInfo { var id: String; var chatType = ChatType.direct }
struct ChatStats { var unreadCount = 0 }
struct Chat {
    var id: String { chatInfo.id }
    var chatInfo: ChatInfo
    var chatItems: [ChatItem]
    var chatStats = ChatStats()
}
struct NavigationInfo { var afterTotal = 0; var afterUnread = 0 }
final class BoxedValue<T> { var boxedValue: T; init(_ value: T) { boxedValue = value } }
final class ActiveChatState {
    var splits: [Int64] = []
    var unreadAfterItemId: Int64 = 0
    var totalAfter = 0
    var unreadTotal = 0
    var unreadAfter = 0
    var unreadAfterNewestLoaded = 0
    func clear() {
        splits = []; unreadAfterItemId = 0; totalAfter = 0
        unreadTotal = 0; unreadAfter = 0; unreadAfterNewestLoaded = 0
    }
    func moveUnreadAfterItem(_ old: Int, _ new: Int, _ items: [ChatItem]) {}
    func moveUnreadAfterItem(_ id: Int64, _ items: [ChatItem]) {}
}
final class PreloadState { func clear() {} }
final class ItemsModel {
    var reversedChatItems: [ChatItem] = []
    var chatState = ActiveChatState()
    var preloadState = PreloadState()
    var secondaryIMFilter: Int? = nil
    var groupScopeInfo: GroupScopeInfo? = nil
    var contentTag: MsgContentTag? = nil
    var isLoading = false
    var showLoadingProgress: ChatId? = nil
    var messageLoadError: ChatId? = nil
    var messageLoadInterrupted: ChatId? = nil
    var messageLoadId = UUID()
    var messageLoadChatId: ChatId? = nil
    var messageLoadUserId: Int64? = nil
    var messageLoadAlternateStore = false
    var navigationTimeoutTask: Task<Void, Never>?
    var loadChatTask: Task<Void, Never>?
}
struct User { var userId: Int64 }
final class ChatModel {
    static var shared = ChatModel()
    var currentUser: User? = User(userId: 1)
    var contentViewAccessAuthenticated = true
    var chatId: ChatId? = "a"
    var openAroundItemId: Int64? = nil
    func getChat(_ id: String) -> Chat? { nil }
    func addChat(_ chat: Chat) {}
    func updateChatInfo(_ info: ChatInfo) {}
}
enum StorageScope { case primary, decoy }
var scope = StorageScope.primary
func xauXatStorageScope() -> StorageScope { scope }
struct Secret { func get() -> String? { decoyConfigured ? "configured" : nil } }
let kcDecoyPassword = Secret()
var decoyConfigured = false
final class UIApplication {
    enum State { case active, inactive, background }
    static var shared = UIApplication()
    var applicationState = State.active
}
final class AppSheetState {
    static var shared = AppSheetState()
    var scenePhaseActive = true
}
var storeOpen = true
func isChatStoreOpen() -> Bool { storeOpen }
struct Logger { func error(_ message: String) {} }
let logger = Logger()
func responseError(_ error: Error) -> String { "synthetic store failure" }
let loadItemsPerPage = 50
enum TestError: Error { case unavailable }
@MainActor
final class XauXatConnectionRecoveryManager {
    enum Scope { case all }
    enum Reason { case foreground }
    static var shared = XauXatConnectionRecoveryManager()
    var attempts = 0
    var recover: () async throws -> Void = { storeOpen = true }
    func reconnect(_ scope: Scope, reason: Reason) async throws {
        attempts += 1
        try await recover()
    }
}
@MainActor
var fetch: (ChatId, ChatPagination, String) async throws -> (Chat, NavigationInfo) = { id, _, _ in
    (Chat(chatInfo: ChatInfo(id: id), chatItems: [ChatItem(id: 1)]), NavigationInfo())
}
@MainActor
func apiGetChat(chatId: ChatId, scope: GroupChatScope?, contentTag: MsgContentTag?, pagination: ChatPagination, search: String) async throws -> (Chat, NavigationInfo) {
    try await fetch(chatId, pagination, search)
}

@main struct HistoryTests {
    @MainActor static func main() async {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func reset() -> ItemsModel {
            ChatModel.shared = ChatModel()
            UIApplication.shared = UIApplication()
            AppSheetState.shared = AppSheetState()
            XauXatConnectionRecoveryManager.shared = XauXatConnectionRecoveryManager()
            scope = .primary; decoyConfigured = false; storeOpen = true
            return ItemsModel()
        }
        func response(_ id: String, _ items: [Int64]) -> (Chat, NavigationInfo) {
            (Chat(chatInfo: ChatInfo(id: id), chatItems: items.map { ChatItem(id: $0) }), NavigationInfo())
        }

        var im = reset()
        var attempts = 0
        fetch = { id, _, _ in
            attempts += 1
            if attempts == 1 { throw TestError.unavailable }
            return response(id, [1, 2])
        }
        await loadChat(chatId: "a", im: im)
        expect(attempts == 2 && im.reversedChatItems.map(\.id) == [2, 1], "Transient read failure must retry and restore history")
        expect(!im.isLoading && im.messageLoadError == nil && im.showLoadingProgress == nil, "Successful retry clears progress and error")
        let refreshIM = im
        fetch = { id, _, _ in
            expect(!refreshIM.isLoading, "Foreground refresh must not trigger initial scroll positioning")
            let visible = Chat(chatInfo: ChatInfo(id: id), chatItems: [ChatItem(id: 2)])
            expect(!shouldRetryMessageHistory(chat: visible, im: refreshIM), "An in-flight foreground refresh is not an interrupted read and cannot trigger a duplicate retry")
            return response(id, [1, 2])
        }
        await loadChat(chatId: "a", im: im, clearItems: false)

        attempts = 0
        fetch = { _, _, _ in attempts += 1; throw TestError.unavailable }
        await loadChat(chatId: "a", im: im)
        expect(attempts == 3 && im.messageLoadError == "a", "Persistent failures expose a bounded retry state")
        expect(im.reversedChatItems.map(\.id) == [2, 1], "Failed refresh preserves existing messages")
        expect(!im.isLoading && im.showLoadingProgress == nil, "Persistent failure cannot leave a spinner running")
        fetch = { id, _, _ in response(id, [3]) }
        await loadChat(chatId: "a", im: im)
        expect(im.messageLoadError == nil && im.reversedChatItems.map(\.id) == [3], "Manual retry succeeds without restarting the app")

        im = reset(); storeOpen = false
        fetch = { id, _, _ in
            precondition(storeOpen, "Never query a closed store")
            return response(id, [4])
        }
        await loadChat(chatId: "a", im: im)
        expect(XauXatConnectionRecoveryManager.shared.attempts == 1 && im.reversedChatItems.first?.id == 4, "Closed store resumes before history query")
        storeOpen = true
        XauXatConnectionRecoveryManager.shared.recover = { throw TestError.unavailable }
        await loadChat(chatId: "a", im: im)
        expect(XauXatConnectionRecoveryManager.shared.attempts == 1, "Open local history never requires relay/network recovery")

        im = reset(); storeOpen = false; attempts = 0
        XauXatConnectionRecoveryManager.shared.recover = { throw TestError.unavailable }
        fetch = { id, _, _ in attempts += 1; return response(id, [5]) }
        await loadChat(chatId: "a", im: im)
        expect(attempts == 0 && im.messageLoadError == "a", "Failed session reopening cannot query the store or report an empty history")

        im = reset()
        fetch = { id, _, _ in response(id, [1]) }
        await loadChat(chatId: "a", im: im)
        fetch = { _, _, _ in throw TestError.unavailable }
        await loadChat(chatId: "b", im: im)
        expect(im.reversedChatItems.isEmpty && im.messageLoadError == "b", "Switching conversation must clear the previous history even if loading fails")

        im = reset()
        fetch = { id, _, _ in response(id, []) }
        await loadChat(chatId: "a", im: im)
        expect(im.reversedChatItems.isEmpty && im.messageLoadError == nil, "A successfully loaded empty conversation is valid")

        im = reset(); attempts = 0
        fetch = { id, _, _ in
            attempts += 1
            withUnsafeCurrentTask { $0?.cancel() }
            return response(id, [9])
        }
        let cancelledIM = im
        _ = await Task { await loadChat(chatId: "a", im: cancelledIM) }.value
        expect(attempts == 1 && im.reversedChatItems.isEmpty && im.messageLoadError == nil, "Cancellation cannot publish data, an error or retry")

        for change in 0..<4 {
            im = reset()
            fetch = { id, _, _ in
                switch change {
                case 0: ChatModel.shared.currentUser = User(userId: 2)
                case 1: scope = .decoy
                case 2: UIApplication.shared.applicationState = .background
                default: decoyConfigured = true; ChatModel.shared.contentViewAccessAuthenticated = false
                }
                return response(id, [9])
            }
            await loadChat(chatId: "a", im: im)
            expect(im.reversedChatItems.isEmpty && im.messageLoadError == nil, "Profile, store, background and lock changes reject stale results")
        }

        im = reset()
        let latestIM = im
        var late: CheckedContinuation<(Chat, NavigationInfo), Error>?
        fetch = { id, _, _ in
            if id == "a" { return try await withCheckedThrowingContinuation { late = $0 } }
            return response(id, [7])
        }
        let first = Task { await loadChat(chatId: "a", im: latestIM) }
        while late == nil { await Task.yield() }
        await loadChat(chatId: "b", im: im)
        late!.resume(returning: response("a", [99]))
        _ = await first.value
        expect(im.reversedChatItems.map(\.id) == [7] && im.messageLoadError == nil, "A late response cannot overwrite a newer conversation")

        im = reset()
        let pendingIM = im
        var oldResponse: CheckedContinuation<(Chat, NavigationInfo), Error>?
        var newResponse: CheckedContinuation<(Chat, NavigationInfo), Error>?
        fetch = { id, _, _ in
            try await withCheckedThrowingContinuation {
                if id == "a" { oldResponse = $0 } else { newResponse = $0 }
            }
        }
        let oldRequest = Task { await loadChat(chatId: "a", im: pendingIM) }
        while oldResponse == nil { await Task.yield() }
        let newRequest = Task { await loadChat(chatId: "b", im: pendingIM) }
        while newResponse == nil { await Task.yield() }
        oldResponse!.resume(throwing: TestError.unavailable)
        _ = await oldRequest.value
        expect(im.isLoading && im.messageLoadError == nil, "Old failure cannot clear the newer request's loading state")
        UIApplication.shared.applicationState = .background
        let generation = im.messageLoadId
        await loadChat(chatId: "c", im: im)
        expect(im.messageLoadId == generation, "A background request cannot supersede an in-flight foreground request")
        UIApplication.shared.applicationState = .active
        newResponse!.resume(returning: response("b", [8]))
        _ = await newRequest.value
        expect(!im.isLoading && im.reversedChatItems.map(\.id) == [8], "The latest request alone completes loading")

        im = reset(); let searchIM = im
        fetch = { id, _, _ in response(id, [1, 2]) }
        await loadChat(chatId: "a", im: im)
        fetch = { id, _, search in
            expect(searchIM.reversedChatItems.map(\.id) == [2, 1], "Keep existing history until replacement is ready")
            expect(search == "needle", "Retry preserves search parameters")
            return response(id, [2])
        }
        await loadChat(chatId: "a", im: im, search: "needle")
        expect(im.reversedChatItems.map(\.id) == [2], "Search replacement must not append unfiltered cached messages")

        im = reset()
        fetch = { id, _, _ in response(id, []) }
        await loadChat(chatId: "a", im: im, openAroundItemId: 55)
        expect(im.messageLoadError == "a", "A deleted search target cannot crash around-item pagination")

        im = reset()
        im.reversedChatItems = [ChatItem(id: 2), ChatItem(id: 1)]
        fetch = { id, _, _ in response(id, [2, 3]) }
        let loaded = await apiLoadMessages("a", im, .last(count: 50))
        expect(loaded && im.reversedChatItems.map(\.id) == [3, 2, 1], "Normal pagination still merges and deduplicates items")

        // P1: the real authorized-open function must not navigate when Face ID
        // completes before UIKit/SwiftUI have restored the active scene.
        im = reset()
        let authIM = im
        im.reversedChatItems = [ChatItem(id: 10)]
        UIApplication.shared.applicationState = .inactive
        AppSheetState.shared.scenePhaseActive = false
        attempts = 0
        var navigations = 0
        fetch = { id, _, _ in attempts += 1; return response(id, [20]) }
        im.loadOpenChatAuthorized("b") { navigations += 1 }
        try? await Task.sleep(nanoseconds: 350_000_000)
        expect(attempts == 0 && navigations == 0 && ChatModel.shared.chatId == "a", "An inactive authentication callback cannot load or navigate")
        expect(im.reversedChatItems.map(\.id) == [10], "Pending authentication return preserves the source history")
        UIApplication.shared.applicationState = .active
        try? await Task.sleep(nanoseconds: 75_000_000)
        expect(attempts == 0 && navigations == 0, "UIKit active alone cannot bypass an inactive SwiftUI scene")
        AppSheetState.shared.scenePhaseActive = true
        await authIM.loadChatTask?.value
        await authIM.navigationTimeoutTask?.value
        expect(attempts == 1 && navigations == 1 && ChatModel.shared.chatId == "b", "The authorized open resumes and navigates exactly once when active")
        expect(im.reversedChatItems.map(\.id) == [20], "The destination never renders the previous conversation's history")

        im = reset()
        UIApplication.shared.applicationState = .inactive
        im.loadOpenChatNoWaitAuthorized("b")
        await Task.yield()
        UIApplication.shared.applicationState = .background
        await im.loadChatTask?.value
        expect(ChatModel.shared.chatId == "a" && im.navigationTimeoutTask == nil, "A backgrounded no-wait open cannot navigate after an aborted read")

        // Superseding/cancelling an inactive authorization must not wake a stale
        // navigation when the scene eventually becomes active.
        im = reset()
        UIApplication.shared.applicationState = .inactive
        fetch = { id, _, _ in response(id, id == "c" ? [30] : [20]) }
        im.loadOpenChatAuthorized("b")
        let superseded = im.loadChatTask
        await Task.yield()
        im.loadOpenChatAuthorized("c")
        UIApplication.shared.applicationState = .active
        await superseded?.value
        await im.loadChatTask?.value
        await im.navigationTimeoutTask?.value
        expect(ChatModel.shared.chatId == "c" && im.reversedChatItems.map(\.id) == [30], "A superseded inactive open cannot navigate or publish old history")

        for change in 0..<2 {
            im = reset()
            UIApplication.shared.applicationState = .inactive
            im.loadOpenChatAuthorized("b")
            while im.messageLoadChatId == nil { await Task.yield() }
            if change == 0 { ChatModel.shared.currentUser = User(userId: 2) }
            else { scope = .decoy }
            UIApplication.shared.applicationState = .active
            await im.loadChatTask?.value
            expect(ChatModel.shared.chatId == "a" && im.navigationTimeoutTask == nil, "Profile/store changes cancel an inactive authorized navigation")
        }

        // P2: a failed/deleted forwarded-message target must leave the source
        // conversation and all of its pagination state usable.
        for deleted in [false, true] {
            im = reset()
            fetch = { id, _, _ in response(id, [1, 2]) }
            await loadChat(chatId: "a", im: im)
            im.chatState.splits = [1]
            im.chatState.totalAfter = 9
            attempts = 0
            fetch = { id, _, _ in
                attempts += 1
                if deleted { return response(id, []) }
                throw TestError.unavailable
            }
            im.loadOpenChatNoWaitAuthorized("b", 99)
            await im.loadChatTask?.value
            expect(attempts == 3 && ChatModel.shared.chatId == "a", "A failed cross-chat jump cannot navigate away from its source")
            expect(im.reversedChatItems.map(\.id) == [2, 1], "A failed/deleted cross-chat target preserves the source messages")
            expect(im.chatState.splits == [1] && im.chatState.totalAfter == 9, "A failed cross-chat jump preserves the source pagination state")
            let source = Chat(chatInfo: ChatInfo(id: "a"), chatItems: [ChatItem(id: 2)])
            expect(!shouldRetryMessageHistory(chat: source, im: im), "A target error cannot replace or retry the still-visible source history")
            fetch = { id, _, _ in response(id, [98, 99]) }
            im.loadOpenChatNoWaitAuthorized("b", 99)
            await im.loadChatTask?.value
            expect(ChatModel.shared.chatId == "b" && ChatModel.shared.openAroundItemId == 99, "A successful retry navigates to the forwarded target")
            expect(im.reversedChatItems.map(\.id) == [99, 98] && im.chatState.totalAfter == 0, "A successful cross-chat jump replaces source messages and pagination")
        }

        // Ordinary navigation still opens the destination's Retry UI after a
        // persistent failure, with none of the source's messages underneath it.
        im = reset()
        im.reversedChatItems = [ChatItem(id: 10)]
        fetch = { _, _, _ in throw TestError.unavailable }
        im.loadOpenChatAuthorized("b")
        await im.loadChatTask?.value
        await im.navigationTimeoutTask?.value
        expect(ChatModel.shared.chatId == "b" && im.messageLoadError == "b" && im.reversedChatItems.isEmpty, "Failed ordinary navigation shows Retry for the correct empty destination")

        // P2: secondary histories intentionally have no preview items. The
        // production foreground decision must retry an interrupted read anyway.
        im = reset()
        im.secondaryIMFilter = 1
        let secondaryIM = im
        let secondary = Chat(chatInfo: ChatInfo(id: "secondary"), chatItems: [])
        var secondaryRead: CheckedContinuation<(Chat, NavigationInfo), Error>?
        fetch = { _, _, _ in try await withCheckedThrowingContinuation { secondaryRead = $0 } }
        let interrupted = Task { await loadChat(chatId: secondary.id, im: secondaryIM) }
        while secondaryRead == nil { await Task.yield() }
        expect(!shouldRetryMessageHistory(chat: secondary, im: im), "An in-flight secondary read cannot start a duplicate foreground retry")
        UIApplication.shared.applicationState = .background
        secondaryRead!.resume(returning: response(secondary.id, [40]))
        _ = await interrupted.value
        expect(im.reversedChatItems.isEmpty && im.messageLoadError == nil && im.messageLoadInterrupted == secondary.id, "A backgrounded secondary read retains explicit interrupted state")
        UIApplication.shared.applicationState = .active
        expect(shouldRetryMessageHistory(chat: secondary, im: im), "Foreground retries interrupted secondary histories even with an empty preview")
        ChatModel.shared.currentUser = User(userId: 2)
        expect(!shouldRetryMessageHistory(chat: secondary, im: im), "Interrupted history belongs to its original profile")
        ChatModel.shared.currentUser = User(userId: 1)
        scope = .decoy
        expect(!shouldRetryMessageHistory(chat: secondary, im: im), "Interrupted history belongs to its original storage scope")
        scope = .primary
        fetch = { id, _, _ in response(id, [40]) }
        if shouldRetryMessageHistory(chat: secondary, im: im) { await loadChat(chat: secondary, im: im) }
        expect(im.reversedChatItems.map(\.id) == [40] && im.messageLoadInterrupted == nil, "Foreground retry restores the secondary messages and clears interrupted state")
        expect(!shouldRetryMessageHistory(chat: secondary, im: im), "A completed secondary read does not retry on every foreground event")
        fetch = { id, _, _ in response(id, []) }
        await loadChat(chatId: secondary.id, im: im)
        expect(!shouldRetryMessageHistory(chat: secondary, im: im), "A successfully loaded empty secondary history must stay empty without repeated retries")
        print("Message history: \(checks) checks passed")
    }
}
