//
//  SimpleXApp.swift
//  Shared
//
//  Created by Evgeny Poberezkin on 17/01/2022.
//
// Spec: spec/architecture.md

import SwiftUI
import OSLog
import StoreKit
import SimpleXChat

let logger = Logger()

@main
// Spec: spec/architecture.md#SimpleXApp
struct SimpleXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var chatModel = ChatModel.shared
    @StateObject private var plusEntitlements = XauXatPlusEntitlements.shared
    @ObservedObject var alertManager = AlertManager.shared

    @Environment(\.scenePhase) var scenePhase
    @State private var enteredBackgroundAuthenticated: TimeInterval? = nil

    init() {
        DispatchQueue.global(qos: .background).sync {
            haskell_init()
//            hs_init(0, nil)
        }
        UserDefaults.standard.register(defaults: appDefaults)
        setGroupDefaults()
        registerGroupDefaults()
        // The real store is the neutral launch default. When a decoy PIN is
        // configured, neither store is opened until the user enters a PIN.
        setXauXatStorageScope(.primary)
        // A SOCKS port persisted by a previous process is never trusted.
        // Every launch remains offline until this process boots embedded Tor.
        setXauXatTorSocksPort(nil)
        setDbContainer()
        BGManager.shared.register()
        NtfManager.shared.registerCategories()
    }

    var body: some Scene {
        WindowGroup {
            // contentAccessAuthenticationExtended has to be passed to ContentView on view initialization,
            // so that it's computed by the time view renders, and not on event after rendering
            ContentView(contentAccessAuthenticationExtended: !authenticationExpired())
                .environmentObject(chatModel)
                .environmentObject(plusEntitlements)
                .environmentObject(AppTheme.shared)
                .onOpenURL { url in
                    logger.debug("ContentView.onOpenURL: \(url)")
                    if AppChatState.shared.value == .active {
                        chatModel.appOpenUrl = url
                    } else {
                        chatModel.appOpenUrlLater = url
                    }
                }
                .onAppear() {
                    plusEntitlements.start()
                    // Present screen for continue migration if it wasn't finished yet
                    if chatModel.migrationState != nil {
                        // It's important, otherwise, user may be locked in undefined state
                        onboardingStageDefault.set(.step1_SimpleXInfo)
                        chatModel.onboardingStage = onboardingStageDefault.get()
                    }
                    startEmbeddedTor(showError: true) {
                        let hasAlternatePIN = kcSelfDestructPassword.get() != nil || kcDecoyPassword.get() != nil
                        if chatModel.migrationState == nil &&
                           (kcAppPassword.get() == nil || !hasAlternatePIN) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                initChatAndMigrate()
                            }
                        }
                    }
                }
// Spec: spec/architecture.md#scenePhaseHandling
                .onChange(of: scenePhase) { phase in
                    logger.debug("scenePhase was \(String(describing: scenePhase)), now \(String(describing: phase))")
                    AppSheetState.shared.scenePhaseActive = phase == .active
                    switch (phase) {
                    case .background:
                        // --- authentication
                        // see ContentView .onChange(of: scenePhase) for remaining authentication logic
                        if chatModel.contentViewAccessAuthenticated {
                            enteredBackgroundAuthenticated = ProcessInfo.processInfo.systemUptime
                        }
                        chatModel.contentViewAccessAuthenticated = false
                        // authentication ---

                        if CallController.useCallKit() && chatModel.activeCall != nil {
                            CallController.shared.shouldSuspendChat = true
                        } else {
                            suspendChat()
                            BGManager.shared.schedule()
                        }
                        NtfManager.shared.setNtfBadgeCount(chatModel.totalUnreadCountForAllUsers())
                    case .active:
                        CallController.shared.shouldSuspendChat = false
                        startEmbeddedTor {
                            resumeChatAfterTor()
                        }
                    default:
                        break
                    }
                }
        }
    }

    private func startEmbeddedTor(showError: Bool = false, _ completion: @escaping () -> Void) {
        EmbeddedTorManager.shared.start { result in
            switch result {
            case .success:
                completion()
            case let .failure(error):
                if showError {
                    AlertManager.shared.showAlert(Alert(
                        title: Text("Private connection unavailable"),
                        message: Text("XauXat could not establish its private connection. No chat traffic was sent directly.\n\n\(error.localizedDescription)"),
                        primaryButton: .default(Text("Retry")) {
                            startEmbeddedTor(showError: true, completion)
                        },
                        secondaryButton: .cancel()
                    ))
                }
            }
        }
    }

    private func resumeChatAfterTor() {
        // With a decoy PIN configured, the unlock PIN must select the storage
        // scope before the native core is allowed to open either database.
        if kcDecoyPassword.get() != nil && !chatModel.contentViewAccessAuthenticated {
            return
        }
        let appState = AppChatState.shared.value
        guard appState != .stopped else { return }

        startChatAndActivate {
            guard chatModel.chatRunning == true else { return }
            if let ntfResponse = chatModel.notificationResponse {
                chatModel.notificationResponse = nil
                NtfManager.shared.processNotificationResponse(ntfResponse)
            }
            if appState.inactive {
                Task {
                    await updateChats()
                    if !chatModel.showCallView && !CallController.shared.hasActiveCalls() {
                        await updateCallInvitations()
                    }
                    if let url = chatModel.appOpenUrlLater {
                        await MainActor.run {
                            chatModel.appOpenUrlLater = nil
                            chatModel.appOpenUrl = url
                        }
                    }
                }
            } else if let url = chatModel.appOpenUrlLater {
                chatModel.appOpenUrlLater = nil
                chatModel.appOpenUrl = url
            }
        }
    }

    private func setDbContainer() {
// Uncomment and run once to open DB in app documents folder:
//         dbContainerGroupDefault.set(.documents)
//         v3DBMigrationDefault.set(.offer)
// to create database in app documents folder also uncomment:
//         let legacyDatabase = true
        let legacyDatabase = hasLegacyDatabase()
        if legacyDatabase, case .documents = dbContainerGroupDefault.get() {
            dbContainerGroupDefault.set(.documents)
            setMigrationState(.offer)
            logger.debug("SimpleXApp init: using legacy DB in documents folder: \(getAppDatabasePath())*.db")
        } else {
            dbContainerGroupDefault.set(.group)
            setMigrationState(.ready)
            logger.debug("SimpleXApp init: using DB in app group container: \(getAppDatabasePath())*.db")
            logger.debug("SimpleXApp init: legacy DB\(legacyDatabase ? "" : " not") present")
        }
    }

    private func setMigrationState(_ state: V3DBMigrationState) {
        if case .migrated = v3DBMigrationDefault.get() { return }
        v3DBMigrationDefault.set(state)
    }

    private func authenticationExpired() -> Bool {
        if let enteredBackgroundAuthenticated = enteredBackgroundAuthenticated {
            let delay = Double(UserDefaults.standard.integer(forKey: DEFAULT_LA_LOCK_DELAY))
            return ProcessInfo.processInfo.systemUptime - enteredBackgroundAuthenticated >= delay
        } else {
            return true
        }
    }

    private func updateChats() async {
        do {
            let chats = try await apiGetChatsAsync()
            await MainActor.run { chatModel.updateChats(chats) }
            if let id = chatModel.chatId,
               let chat = chatModel.getChat(id),
               !NtfManager.shared.navigatingToChat {
                Task { await loadChat(chat: chat, im: ItemsModel.shared, clearItems: false) }
            }
            if let ncr = chatModel.ntfContactRequest {
                await MainActor.run { chatModel.ntfContactRequest = nil }
                if case let .contactRequest(contactRequest) = chatModel.getChat(ncr.chatId)?.chatInfo {
                    Task { await acceptContactRequest(incognito: false, contactRequestId: contactRequest.apiId) }
                }
            }
        } catch let error {
            logger.error("apiGetChats: cannot update chats \(responseError(error))")
        }
    }

    private func updateCallInvitations() async {
        do {
            try await refreshCallInvitations()
        } catch let error {
            logger.error("apiGetCallInvitations: cannot update call invitations \(responseError(error))")
        }
    }
}

enum XauXatPlusFeature: String, CaseIterable {
    case decoyPIN
    case duressPIN
    case conversationLock
    case hiddenChats
    case protectedProfiles
    case pressToPreview
    case codeLockedContent
    case advancedVoiceMasking
    case realTimeVoiceMasking
    case advancedContactInvites
    case multipleIdentities
    case largeGroups
    case secureGroupAccess
}

@MainActor
protocol XauXatPlusAuthorizing: AnyObject {
    func isAuthorized(for feature: XauXatPlusFeature) -> Bool
}

enum XauXatPlusStatus: Equatable {
    case checking
    case notPurchased
    case active(expiresAt: Date?, willAutoRenew: Bool)
    case expired(expiresAt: Date?)
    case revoked(at: Date?)
    case unverified
    case unavailable

    var hasAccess: Bool {
        if case .active = self { true } else { false }
    }
}

enum XauXatPlusConfiguration {
    static let fallbackProductID = "pt.exsoria.xauxat.plus.monthly"

    static var productID: String {
        if let override = ProcessInfo.processInfo.environment["XAUXAT_PLUS_PRODUCT_ID"],
           !override.isEmpty {
            return override
        }
        if let configured = Bundle.main.object(forInfoDictionaryKey: "XauXatPlusProductID") as? String,
           !configured.isEmpty,
           !configured.contains("$(") {
            return configured
        }
        return fallbackProductID
    }
}

@MainActor
final class XauXatPlusEntitlements: ObservableObject, XauXatPlusAuthorizing {
    static let shared = XauXatPlusEntitlements()

    @Published private(set) var status: XauXatPlusStatus = .checking
    @Published private(set) var product: Product?
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published var presentedError: String?

    private var updatesTask: Task<Void, Never>?
    private var started = false

    var productID: String { XauXatPlusConfiguration.productID }

    var displayPrice: String {
        product.map { "\($0.displayPrice) / month" } ?? "€2.99 / month"
    }

    var hasAccess: Bool {
#if DEBUG
        true
#else
        status.hasAccess
#endif
    }

    var hasLocalDebugAccess: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    func isAuthorized(for feature: XauXatPlusFeature) -> Bool {
        hasAccess
    }

    func start() {
        guard !started else { return }
        started = true
        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await verification in Transaction.updates {
                guard !Task.isCancelled else { return }
                if case let .verified(transaction) = verification,
                   transaction.productID == self.productID {
                    await self.refresh()
                    await transaction.finish()
                } else if case let .unverified(transaction, _) = verification,
                          transaction.productID == self.productID {
                    self.status = .unverified
                }
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        status = .checking
        do {
            let candidate = try await Product.products(for: [productID]).first
            if candidate?.type == .autoRenewable,
               let period = candidate?.subscription?.subscriptionPeriod,
               period.unit == .month,
               period.value == 1 {
                product = candidate
            } else {
                product = nil
            }
        } catch {
            product = nil
        }

        var foundUnverified = false
        for await verification in Transaction.currentEntitlements {
            switch verification {
            case let .verified(transaction) where transaction.productID == productID:
                // StoreKit includes subscriptions in billing grace period in
                // currentEntitlements, so presence here is the source of truth
                // even when the original expiration date has passed.
                if transaction.revocationDate == nil {
                    let willAutoRenew = await renewalWillAutoRenew(for: transaction.id) ?? true
                    status = .active(expiresAt: transaction.expirationDate, willAutoRenew: willAutoRenew)
                    return
                }
            case let .unverified(transaction, _) where transaction.productID == productID:
                foundUnverified = true
            default:
                break
            }
        }

        if foundUnverified {
            status = .unverified
            return
        }

        if let latest = await Transaction.latest(for: productID) {
            switch latest {
            case let .verified(transaction):
                if let revokedAt = transaction.revocationDate {
                    status = .revoked(at: revokedAt)
                } else if let expiresAt = transaction.expirationDate, expiresAt <= Date() {
                    status = .expired(expiresAt: expiresAt)
                } else {
                    status = .notPurchased
                }
            case .unverified:
                status = .unverified
            }
        } else {
            status = product == nil ? .unavailable : .notPurchased
        }
    }

    func purchase() async {
        guard let product else {
            presentedError = NSLocalizedString("XauXat Plus is not available from the App Store in this build.", comment: "StoreKit product unavailable")
            return
        }
        guard AppStore.canMakePayments else {
            presentedError = NSLocalizedString("Purchases are disabled on this device.", comment: "StoreKit payments unavailable")
            return
        }

        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case let .success(.verified(transaction)):
                guard transaction.productID == productID else {
                    presentedError = NSLocalizedString("The App Store returned an unexpected product.", comment: "StoreKit wrong product")
                    return
                }
                await refresh()
                await transaction.finish()
            case .success(.unverified):
                status = .unverified
                presentedError = NSLocalizedString("The purchase could not be verified by the App Store.", comment: "StoreKit unverified transaction")
            case .pending:
                presentedError = NSLocalizedString("The purchase is pending approval. Access will unlock automatically when the App Store confirms it.", comment: "StoreKit pending purchase")
            case .userCancelled:
                break
            @unknown default:
                await refresh()
            }
        } catch {
            presentedError = error.localizedDescription
            await refresh()
        }
    }

    func restorePurchases() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
            await refresh()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func renewalWillAutoRenew(for transactionID: UInt64) async -> Bool? {
        guard let subscription = product?.subscription,
              let statuses = try? await subscription.status else { return nil }
        for subscriptionStatus in statuses {
            guard case let .verified(transaction) = subscriptionStatus.transaction,
                  transaction.id == transactionID,
                  case let .verified(renewalInfo) = subscriptionStatus.renewalInfo else { continue }
            return renewalInfo.willAutoRenew
        }
        return nil
    }
}
