//
//  ContentView.swift
//  Shared
//
//  Created by Evgeny Poberezkin on 17/01/2022.
//
// Spec: spec/client/navigation.md

import SwiftUI
import Intents
import SimpleXChat

private enum NoticesSheet: Identifiable {
    case updatedConditions

    var id: String {
        switch self {
        case .updatedConditions: return "updatedConditions"
        }
    }
}

// Spec: spec/client/navigation.md#ContentView
struct ContentView: View {
    @EnvironmentObject var chatModel: ChatModel
    @ObservedObject var alertManager = AlertManager.shared
    @ObservedObject var callController = CallController.shared
    // Spec: spec/client/navigation.md#AppSheetState
    @ObservedObject var appSheetState = AppSheetState.shared
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var sceneDelegate: SceneDelegate

    // Spec: spec/client/navigation.md#contentAccessAuthenticationExtended
    var contentAccessAuthenticationExtended: Bool

    @Environment(\.scenePhase) var scenePhase
    @State private var automaticAuthenticationAttempted = false
    @State private var canConnectViewCall = false
    @State private var lastSuccessfulUnlock: TimeInterval? = nil

    @AppStorage(DEFAULT_SHOW_LA_NOTICE) private var prefShowLANotice = false
    @AppStorage(DEFAULT_LA_NOTICE_SHOWN) private var prefLANoticeShown = false
    @AppStorage(DEFAULT_PERFORM_LA) private var prefPerformLA = false
    @AppStorage(DEFAULT_PRIVACY_PROTECT_SCREEN) private var protectScreen = false
    @AppStorage(DEFAULT_NOTIFICATION_ALERT_SHOWN) private var notificationAlertShown = false
    @State private var noticesShown = false
    @State private var noticesSheetItem: NoticesSheet? = nil
    @State private var showChooseLAMode = false
    @State private var showSetPasscode = false
    @State private var waitingForOrPassedAuth = true
    @State private var chatListUserPickerSheet: UserPickerSheet? = nil

    private let callTopPadding: CGFloat = 40

    private var accessAuthenticated: Bool {
        chatModel.contentViewAccessAuthenticated || contentAccessAuthenticationExtended
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                allViews()
                    .scrollContentBackground(.hidden)
            } else {
                // on iOS 15 scroll view background disabled in SceneDelegate
                allViews()
            }
        }
        .modifier(XauXatAppSwitcherProtection())
    }

    func allViews() -> some View {
        ZStack {
            let showCallArea = chatModel.activeCall != nil && chatModel.activeCall?.callState != .waitCapabilities && chatModel.activeCall?.callState != .invitationAccepted
            // contentView() has to be in a single branch, so that enabling authentication doesn't trigger re-rendering and close settings.
            // i.e. with separate branches like this settings are closed: `if prefPerformLA { ... contentView() ... } else { contentView() }
            if !prefPerformLA || accessAuthenticated {
                contentView()
                    .padding(.top, showCallArea ? callTopPadding : 0)
            } else {
                lockButton()
                    .padding(.top, showCallArea ? callTopPadding : 0)
            }

            if showCallArea, let call = chatModel.activeCall {
                VStack {
                    activeCallInteractiveArea(call)
                    Spacer()
                }
            }

            if chatModel.showCallView, let call = chatModel.activeCall {
                callView(call)
            }

            if chatListUserPickerSheet == nil, let la = chatModel.laRequest {
                LocalAuthView(authRequest: la)
                    .onDisappear {
                        // this flag is separate from accessAuthenticated to show initializationView while we wait for authentication
                        waitingForOrPassedAuth = accessAuthenticated
                    }
            } else if showSetPasscode {
                SetAppPasscodeView {
                    chatModel.contentViewAccessAuthenticated = true
                    prefPerformLA = true
                    showSetPasscode = false
                    privacyLocalAuthModeDefault.set(.passcode)
                    alertManager.showAlert(laTurnedOnAlert())
                } cancel: {
                    prefPerformLA = false
                    showSetPasscode = false
                    alertManager.showAlert(laPasscodeNotSetAlert())
                }
            } else if chatModel.chatDbStatus == nil && AppChatState.shared.value != .stopped && waitingForOrPassedAuth {
                initializationView()
            }
        }
        .alert(isPresented: $alertManager.presentAlert) { alertManager.alertView! }
        .confirmationDialog("App Lock mode", isPresented: $showChooseLAMode, titleVisibility: .visible) {
            Button("System authentication") { initialEnableLA() }
            Button("Passcode entry") { showSetPasscode = true }
        }
        .onChange(of: scenePhase) { phase in
            logger.debug("scenePhase was \(String(describing: scenePhase)), now \(String(describing: phase))")
            switch (phase) {
            case .background:
                // also see .onChange(of: scenePhase) in SimpleXApp: on entering background
                // it remembers enteredBackgroundAuthenticated and sets chatModel.contentViewAccessAuthenticated to false
                automaticAuthenticationAttempted = false
                canConnectViewCall = false
            case .active:
                canConnectViewCall = !prefPerformLA || contentAccessAuthenticationExtended || unlockedRecently()
                
                // condition `!chatModel.contentViewAccessAuthenticated` is required for when authentication is enabled in settings or on initial notice
                if prefPerformLA && !chatModel.contentViewAccessAuthenticated {
                    if AppChatState.shared.value != .stopped {
                        if contentAccessAuthenticationExtended {
                            chatModel.contentViewAccessAuthenticated = true
                        } else {
                            if !automaticAuthenticationAttempted {
                                automaticAuthenticationAttempted = true
                                // authenticate if call kit call is not in progress
                                if !(CallController.useCallKit() && chatModel.showCallView && chatModel.activeCall != nil) {
                                    authenticateContentViewAccess()
                                }
                            }
                        }
                    } else {
                        // when app is stopped automatic authentication is not attempted
                        chatModel.contentViewAccessAuthenticated = contentAccessAuthenticationExtended
                    }
                }
            default:
                break
            }
        }
        .onAppear {
            reactOnDarkThemeChanges(systemInDarkThemeCurrently)
        }
        .onChange(of: colorScheme) { scheme in
            // It's needed to update UI colors when iOS wants to make screenshot after going to background,
            // so when a user changes his global theme from dark to light or back, the app will adapt to it
            reactOnDarkThemeChanges(scheme == .dark)
        }
        .onChange(of: theme.name) { _ in
            ThemeManager.adjustWindowStyle()
        }
    }


    // Spec: spec/client/navigation.md#contentView
    @ViewBuilder private func contentView() -> some View {
        if let status = chatModel.chatDbStatus, status != .ok {
            DatabaseErrorView(status: status)
        } else if !chatModel.v3DBMigration.startChat {
            MigrateToAppGroupView()
        } else if let step = chatModel.onboardingStage {
            if case .onboardingComplete = step,
               chatModel.currentUser != nil {
                mainView()
            } else {
                OnboardingView(onboarding: step)
            }
        }
    }

    // Spec: spec/client/navigation.md#callView
    @ViewBuilder private func callView(_ call: Call) -> some View {
        if CallController.useCallKit() {
            ActiveCallView(call: call, canConnectCall: Binding.constant(true))
                .onDisappear {
                    if prefPerformLA && !accessAuthenticated { authenticateContentViewAccess() }
                }
        } else {
            ActiveCallView(call: call, canConnectCall: $canConnectViewCall)
            if prefPerformLA && !accessAuthenticated {
                Rectangle()
                    .fill(colorScheme == .dark ? .black : .white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                lockButton()
            }
        }
    }

    // Spec: spec/client/navigation.md#callBanner
    private func activeCallInteractiveArea(_ call: Call) -> some View {
        HStack {
            Text(call.contact.displayName).font(.body).foregroundColor(.white)
            Spacer()
            CallDuration(call: call)
        }
        .padding(.horizontal)
        .frame(height: callTopPadding)
        .background(Color(uiColor: UIColor(red: 47/255, green: 208/255, blue: 88/255, alpha: 1)))
        .onTapGesture {
            chatModel.activeCallViewIsCollapsed = false
        }
    }

    struct CallDuration: View {
        let call: Call
        @State var text: String = ""
        @State var timer: Timer? = nil

        var body: some View {
            Text(text).frame(minWidth: text.count <= 5 ? 52 : 77, alignment: .leading).offset(x: 4).font(.body).foregroundColor(.white)
            .onAppear {
                timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
                    if let connectedAt = call.connectedAt {
                        text = durationText(Int(Date.now.timeIntervalSince1970 - connectedAt.timeIntervalSince1970))
                    }
                }
            }
            .onDisappear {
                _ = timer?.invalidate()
            }
        }
    }

    // Spec: spec/client/navigation.md#lockButton
    private func lockButton() -> some View {
        Button(action: authenticateContentViewAccess) { Label("Unlock", systemImage: "lock") }
    }

    private func initializationView() -> some View {
        XauXatOpeningView()
    }

    private func mainView() -> some View {
        ZStack(alignment: .top) {
            XauXatHomeView(activeUserPickerSheet: $chatListUserPickerSheet)
                .redacted(reason: appSheetState.redactionReasons(protectScreen))
            .onAppear {
                // Connect only after the notifications prompt is resolved: the system prompt suspends
                // the app (scene .inactive), which kills an in-flight connect and makes
                // getTopViewController() nil. Deferring keeps the URL until the app is active again.
                let openingViaLink = pendingConnectUrl != nil
                requestNtfAuthorization(showDeniedAlert: !openingViaLink) {
                    connectViaUrl()
                }
                if !openingViaLink {
                    // Local Authentication notice is to be shown on next start after onboarding is complete
                    if (!prefLANoticeShown && prefShowLANotice && chatModel.chats.count > 2) {
                        prefLANoticeShown = true
                        alertManager.showAlert(laNoticeAlert())
                    } else if !chatModel.showCallView && CallController.shared.activeCallInvitation == nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            if !noticesShown {
                                let showUpdatedConditions = chatModel.conditions.conditionsAction?.showNotice ?? false
                                noticesShown = showUpdatedConditions
                                if showUpdatedConditions {
                                    noticesSheetItem = .updatedConditions
                                }
                            }
                        }
                    }
                    showReRegisterTokenAlert()
                }
                prefShowLANotice = true
            }
            .onChange(of: chatModel.appOpenUrl) { _ in connectViaUrl() }
            .onChange(of: chatModel.reRegisterTknStatus) { _ in showReRegisterTokenAlert() }
            .sheet(item: $noticesSheetItem) { item in
                switch item {
                case .updatedConditions:
                    UsageConditionsView(
                        currUserServers: Binding.constant([]),
                        userServers: Binding.constant([])
                    )
                    .modifier(ThemedBackground(grouped: true))
                    .task { await setConditionsNotified_() }
                }
            }
            if chatModel.setDeliveryReceipts {
                SetDeliveryReceiptsView()
            }
            IncomingCallView()
        }
        .onContinueUserActivity("INStartCallIntent", perform: processUserActivity)
        .onContinueUserActivity("INStartAudioCallIntent", perform: processUserActivity)
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
            if let url = userActivity.webpageURL {
                logger.debug("onContinueUserActivity.NSUserActivityTypeBrowsingWeb: \(url)")
                chatModel.appOpenUrl = url
            }
        }
    }

    private func setConditionsNotified_() async {
        do {
            let conditionsId = ChatModel.shared.conditions.currentConditions.conditionsId
            try await setConditionsNotified(conditionsId: conditionsId)
        } catch let error {
            logger.error("setConditionsNotified error: \(responseError(error))")
        }
    }

    private func processUserActivity(_ activity: NSUserActivity) {
        let intent = activity.interaction?.intent
        if let intent = intent as? INStartCallIntent {
            callToRecentContact(intent.contacts)
        } else if let intent = intent as? INStartAudioCallIntent {
            callToRecentContact(intent.contacts)
        }
    }

    private func callToRecentContact(_ contacts: [INPerson]?) {
        logger.debug("callToRecentContact")
        if let contactId = contacts?.first?.personHandle?.value,
           let chat = chatModel.getChat(contactId),
           case let .direct(contact) = chat.chatInfo {
            let activeCall = chatModel.activeCall
            if activeCall == nil {
                logger.debug("callToRecentContact: schedule call")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    CallController.shared.startCall(contact, .audio)
                }
            }
        }
    }

    // Spec: spec/client/navigation.md#unlockedRecently
    private func unlockedRecently() -> Bool {
        if let lastSuccessfulUnlock = lastSuccessfulUnlock {
            return ProcessInfo.processInfo.systemUptime - lastSuccessfulUnlock < 2
        } else {
            return false
        }
    }

    private func authenticateContentViewAccess() {
        logger.debug("DEBUGGING: authenticateContentViewAccess")
        dismissAllSheets(animated: false) {
            logger.debug("DEBUGGING: authenticateContentViewAccess, in dismissAllSheets callback")
            chatModel.chatId = nil

            authenticate(reason: NSLocalizedString("Unlock app", comment: "authentication reason"), selfDestruct: true) { laResult in
                logger.debug("DEBUGGING: authenticate callback: \(String(describing: laResult))")
                switch (laResult) {
                case .success:
                    chatModel.contentViewAccessAuthenticated = true
                    canConnectViewCall = true
                    lastSuccessfulUnlock = ProcessInfo.processInfo.systemUptime
                case .failed:
                    chatModel.contentViewAccessAuthenticated = false
                    if privacyLocalAuthModeDefault.get() == .passcode {
                        AlertManager.shared.showAlert(laFailedAlert())
                    }
                case .unavailable:
                    prefPerformLA = false
                    canConnectViewCall = true
                    AlertManager.shared.showAlert(laUnavailableTurningOffAlert())
                }
            }
        }
    }

    func requestNtfAuthorization(showDeniedAlert: Bool = true, whenDone: (() -> Void)? = nil) {
        NtfManager.shared.requestAuthorization(
            onDeny: {
                if showDeniedAlert, !notificationAlertShown {
                    notificationAlertShown = true
                    alertManager.showAlert(notificationAlert())
                }
            },
            onAuthorized: { notificationAlertShown = false },
            whenDone: { if let whenDone { DispatchQueue.main.async(execute: whenDone) } }
        )
    }

    func laNoticeAlert() -> Alert {
        Alert(
            title: Text("App Lock"),
            message: Text("To protect your information, turn on App Lock.\nYou will be prompted to complete authentication before this feature is enabled."),
            primaryButton: .default(Text("Turn on")) { showChooseLAMode = true },
            secondaryButton: .cancel()
         )
    }

    private func initialEnableLA () {
        privacyLocalAuthModeDefault.set(.system)
        authenticate(reason: NSLocalizedString("Enable App Lock", comment: "authentication reason")) { laResult in
            switch laResult {
            case .success:
                chatModel.contentViewAccessAuthenticated = true
                prefPerformLA = true
                alertManager.showAlert(laTurnedOnAlert())
            case .failed:
                prefPerformLA = false
                alertManager.showAlert(laFailedAlert())
            case .unavailable:
                prefPerformLA = false
                alertManager.showAlert(laUnavailableInstructionAlert())
            }
        }
    }

    func notificationAlert() -> Alert {
        Alert(
            title: Text("Notifications are disabled!"),
            message: Text("The app can notify you when you receive messages or contact requests - please open settings to enable."),
            primaryButton: .default(Text("Open Settings")) {
                DispatchQueue.main.async {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
                }
            },
            secondaryButton: .cancel()
        )
    }

    // Spec: spec/client/navigation.md#connectViaUrl
    // a URL opened via link that is ready to be connected now (appOpenUrl immediately, or
    // appOpenUrlLater once the app is active — see .onChange(of: scenePhase) in SimpleXApp)
    private var pendingConnectUrl: URL? {
        let m = ChatModel.shared
        if let url = m.appOpenUrl { return url }
        if let url = m.appOpenUrlLater, AppChatState.shared.value == .active, scenePhase == .active { return url }
        return nil
    }

    func connectViaUrl() {
        let m = ChatModel.shared
        guard let url = pendingConnectUrl else { return }
        if m.appOpenUrl != nil { m.appOpenUrl = nil } else { m.appOpenUrlLater = nil }
        connectViaUrl_(url)
    }

    func connectViaUrl_(_ url: URL) {
        dismissAllSheets() {
            var path = url.path
            if path == "/r" {
                showAlert(
                    NSLocalizedString("Relay address", comment: "alert title"),
                    message: NSLocalizedString("This is a chat relay address, it cannot be used to connect.", comment: "alert message")
                )
            } else if xauXatIsProtectedGroupInviteLink(url.absoluteString) {
                planAndConnect(url.absoluteString, theme: theme, dismiss: false)
            } else if (path == "/contact" || path == "/invitation" || path == "/a" || path == "/c" || path == "/g" || path == "/i") {
                path.removeFirst()
                let link = url.absoluteString.replacingOccurrences(of: "///\(path)", with: "/\(path)")
                planAndConnect(
                    link,
                    theme: theme,
                    dismiss: false
                )
            } else {
                AlertManager.shared.showAlert(Alert(title: Text("Error: URL is invalid")))
            }
        }
    }

    func showReRegisterTokenAlert() {
        dismissAllSheets() {
            let m = ChatModel.shared
            if let errorTknStatus = m.reRegisterTknStatus, let token = chatModel.deviceToken {
                chatModel.reRegisterTknStatus = nil
                AlertManager.shared.showAlert(Alert(
                    title: Text("Notifications error"),
                    message: Text(tokenStatusInfo(errorTknStatus, register: true)),
                    primaryButton: .default(Text("Register")) { reRegisterToken(token: token) },
                    secondaryButton: .cancel()
                ))
            }
        }
    }
}

final class AlertManager: ObservableObject {
    static let shared = AlertManager()
    @Published var presentAlert = false
    @Published var alertView: Alert?

    func showAlert(_ alert: Alert) {
        logger.debug("AlertManager.showAlert")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.alertView = alert
            self.presentAlert = true
        }
    }

    func showAlertMsg(title: LocalizedStringKey, message: LocalizedStringKey? = nil) {
        showAlert(mkAlert(title: title, message: message))
    }
}

func mkAlert(title: LocalizedStringKey, message: LocalizedStringKey? = nil) -> Alert {
    if let message = message {
        return Alert(title: Text(title), message: Text(message))
    } else {
        return Alert(title: Text(title))
    }
}

//struct ContentView_Previews: PreviewProvider {
//    static var previews: some View {
//        ContentView(text: "Hello!")
//    }
//}


private struct XauXatOpeningView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var gazeX: CGFloat = 0
    @State private var gazeY: CGFloat = 0
    @State private var blinking = false
    @State private var animationTask: Task<Void, Never>?

    @State private var loadingMessageIndex = 0
    @State private var messageTask: Task<Void, Never>?

    private let champagne = Color(
        red: 222 / 255,
        green: 206 / 255,
        blue: 175 / 255
    )

    private var openingBackground: Color {
        colorScheme == .dark
            ? Color.black
            : Color(
                red: 244 / 255,
                green: 240 / 255,
                blue: 232 / 255
            )
    }

    private var openingAccent: Color {
        colorScheme == .dark
            ? champagne
            : Color(
                red: 23 / 255,
                green: 19 / 255,
                blue: 14 / 255
            )
    }

    private var openingEye: Color {
        colorScheme == .dark
            ? Color.white
            : Color(
                red: 23 / 255,
                green: 19 / 255,
                blue: 14 / 255
            )
    }

    private var loadingGray: Color {
        colorScheme == .dark
            ? Color(
                red: 145 / 255,
                green: 142 / 255,
                blue: 136 / 255
            )
            : Color(
                red: 105 / 255,
                green: 97 / 255,
                blue: 88 / 255
            )
    }

    private let loadingMessages: [LocalizedStringKey] = [
        "Connecting to the Tor network…\nthis may take a few seconds.",

        "Fun fact: did you know some messaging apps\nuse your data to train robots?",

        "We know nothing about you.\nAnd we don't want to.",

        "This is the only ad you'll see around here.",

        "Like XauXat? Plus is €2.99.\nYes, this was an ad too.",

        "You can do everything with Free.\nNo ads. No selling your data.",

        "Your XauXat may take a little longer.\nBut it's yours.",

        "Fun fact: with Plus, you can have a second PIN\nthat makes everything disappear.",

        "No email. No phone number.\nWe don't know who you are either.",

        "Your message doesn't need to know your name\nto reach its destination.",

        "We don't have personalized ads.\nWe'd have to know you for that.",

        "Plus: €2.99.\nBecause servers still don't accept privacy as currency.",

        "If you're reading this, Tor is taking its time.\nAt least we gave you something to read."
    ]

    var body: some View {
        ZStack {
            openingBackground
                .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    // Os olhos são desenhados primeiro para ficarem
                    // fisicamente atrás da máscara.
                    HStack(spacing: 39) {
                        // Olho do lado esquerdo do ecrã.
                        eye
                            .offset(
                                x: adjustedLeftEyeX,
                                y: gazeY
                            )

                        // Olho do lado direito do ecrã.
                        // Movimento para dentro ligeiramente limitado
                        // para acompanhar melhor a abertura da máscara.
                        eye
                            .offset(
                                x: adjustedRightEyeX,
                                y: gazeY
                            )
                    }
                    .offset(y: -2)

                    // A máscara fica à frente dos olhos.
                    Image("xauxat-mask")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(openingAccent)
                        .frame(width: 132, height: 104)
                }
                .frame(width: 150, height: 116)

                Text(verbatim: "xauxat")
                    .font(.custom("Courier", size: 25).weight(.bold))
                    .tracking(2.7)
                    .foregroundStyle(openingAccent)
                    .offset(x: 2)

                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(openingAccent)
                        .scaleEffect(0.72)
                        .frame(width: 20, height: 20)

                    Text(loadingMessages[loadingMessageIndex])
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(loadingGray)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(
                            width: 330,
                            height: 42,
                            alignment: .top
                        )
                        .lineLimit(2)
                        .minimumScaleFactor(0.92)
                }
                .frame(height: 78, alignment: .top)
                .padding(.top, 4)
            }
        }
        .onAppear {
            startEyeAnimation()
            startLoadingMessages()
        }
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil

            messageTask?.cancel()
            messageTask = nil
        }
    }

    private var eye: some View {
        Capsule()
            .fill(openingEye)
            .frame(
                width: 9,
                height: blinking ? 2 : 9
            )
    }

    // As aberturas da máscara não são caixas horizontais perfeitas.
    // Ajustamos ligeiramente cada pupila para evitar o efeito estrábico.
    private var adjustedLeftEyeX: CGFloat {
        if gazeX > 0 {
            // Quando olha para a direita, este olho aproxima-se do nariz.
            // Reduzimos ligeiramente esse movimento.
            return gazeX * 0.72
        }

        return gazeX
    }

    private var adjustedRightEyeX: CGFloat {
        if gazeX < 0 {
            // Quando olha para a esquerda, este olho aproxima-se do nariz.
            // Reduzimos ligeiramente esse movimento.
            return gazeX * 0.72
        }

        return gazeX
    }

    private func startLoadingMessages() {
        messageTask?.cancel()

        loadingMessageIndex = 0

        messageTask = Task { @MainActor in
            // Num arranque rápido só aparece o estado da ligação Tor.
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            while !Task.isCancelled {
                loadingMessageIndex =
                    (loadingMessageIndex + 1) % loadingMessages.count

                // Tempo para ler antes da próxima mensagem.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    private func startEyeAnimation() {
        animationTask?.cancel()

        gazeX = 0
        gazeY = 0
        blinking = false

        animationTask = Task { @MainActor in

            // Alterna a direção em cada ciclo.
            var startsLeft = true

            while !Task.isCancelled {

                // Olhar em frente.
                try? await Task.sleep(nanoseconds: 900_000_000)
                if Task.isCancelled { break }

                // Blink normal no centro.
                await blink()
                if Task.isCancelled { break }

                // Continua imóvel durante algum tempo.
                try? await Task.sleep(nanoseconds: 1_250_000_000)
                if Task.isCancelled { break }

                // Primeiro lado deste ciclo.
                let firstX: CGFloat = startsLeft ? -4 : 4
                let firstY: CGFloat = startsLeft ? -0.5 : 0.4

                withAnimation(.easeInOut(duration: 0.28)) {
                    gazeX = firstX
                    gazeY = firstY
                }

                try? await Task.sleep(nanoseconds: 620_000_000)
                if Task.isCancelled { break }

                // Cruza diretamente para o lado oposto.
                let secondX: CGFloat = startsLeft ? 4 : -4
                let secondY: CGFloat = startsLeft ? 0.4 : -0.5

                withAnimation(.easeInOut(duration: 0.34)) {
                    gazeX = secondX
                    gazeY = secondY
                }

                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { break }

                // Blink enquanto olha para o segundo lado.
                await blink()
                if Task.isCancelled { break }

                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { break }

                // Volta suavemente ao centro.
                withAnimation(.easeInOut(duration: 0.28)) {
                    gazeX = 0
                    gazeY = 0
                }

                // Fica bastante tempo imóvel no centro.
                try? await Task.sleep(nanoseconds: 1_450_000_000)
                if Task.isCancelled { break }

                // Novo blink no centro.
                await blink()
                if Task.isCancelled { break }

                try? await Task.sleep(nanoseconds: 1_100_000_000)
                if Task.isCancelled { break }

                // Próximo ciclo começa pelo lado oposto.
                startsLeft.toggle()
            }
        }
    }

    @MainActor
    private func blink() async {
        withAnimation(.easeIn(duration: 0.07)) {
            blinking = true
        }

        try? await Task.sleep(nanoseconds: 105_000_000)

        if Task.isCancelled { return }

        withAnimation(.easeOut(duration: 0.09)) {
            blinking = false
        }

        try? await Task.sleep(nanoseconds: 90_000_000)
    }
}
