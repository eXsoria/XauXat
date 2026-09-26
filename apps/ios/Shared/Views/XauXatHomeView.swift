//
//  XauXatHomeView.swift
//  XauXat
//
//  The native shell for the XauXat product. It intentionally exposes a
//  smaller surface than upstream SimpleX while reusing its real chat, invite,
//  profile and settings implementations underneath.
//

import SwiftUI
import SimpleXChat

private enum XauXatTab: String, CaseIterable, Identifiable {
    case chats
    case contacts
    case notes
    case settings

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .chats: "Chats"
        case .contacts: "Contacts"
        case .notes: "Notes"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "bubble.left"
        case .contacts: "person.2"
        case .notes: "note.text"
        case .settings: "gearshape"
        }
    }
}

private struct XauXatPalette {
    let background: Color
    let surface: Color
    let raised: Color
    let ink: Color
    let muted: Color
    let faint: Color
    let line: Color
    let ivory: Color
    let ivoryInk: Color
    let danger: Color
    let success: Color

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            background = Color(red: 0, green: 0, blue: 0)
            surface = Color(red: 9 / 255, green: 9 / 255, blue: 9 / 255)
            raised = Color(red: 21 / 255, green: 21 / 255, blue: 21 / 255)
            ink = Color(red: 244 / 255, green: 240 / 255, blue: 232 / 255)
            muted = Color(red: 139 / 255, green: 135 / 255, blue: 127 / 255)
            faint = Color(red: 74 / 255, green: 72 / 255, blue: 67 / 255)
            line = Color(red: 37 / 255, green: 35 / 255, blue: 31 / 255)
            ivory = Color(red: 222 / 255, green: 206 / 255, blue: 175 / 255)
            ivoryInk = Color(red: 23 / 255, green: 19 / 255, blue: 14 / 255)
            danger = Color(red: 239 / 255, green: 89 / 255, blue: 89 / 255)
            success = Color(red: 116 / 255, green: 179 / 255, blue: 122 / 255)
        } else {
            background = Color(red: 244 / 255, green: 240 / 255, blue: 232 / 255)
            surface = Color(red: 234 / 255, green: 227 / 255, blue: 215 / 255)
            raised = Color(red: 221 / 255, green: 212 / 255, blue: 198 / 255)
            ink = Color(red: 23 / 255, green: 19 / 255, blue: 14 / 255)
            muted = Color(red: 105 / 255, green: 97 / 255, blue: 88 / 255)
            faint = Color(red: 148 / 255, green: 139 / 255, blue: 128 / 255)
            line = Color(red: 207 / 255, green: 196 / 255, blue: 180 / 255)
            ivory = Color(red: 23 / 255, green: 19 / 255, blue: 14 / 255)
            ivoryInk = Color(red: 244 / 255, green: 240 / 255, blue: 232 / 255)
            danger = Color(red: 184 / 255, green: 41 / 255, blue: 41 / 255)
            success = Color(red: 62 / 255, green: 120 / 255, blue: 71 / 255)
        }
    }
}

private enum XauXatOnboardingField: Hashable {
    case displayName
    case pin
}

struct XauXatWelcomeView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var step = 0
    @State private var displayName = ""
    @State private var pin = ""
    @State private var isCompleting = false
    @State private var profileCreated = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: XauXatOnboardingField?

    private var palette: XauXatPalette { XauXatPalette(colorScheme) }
    private var compactName: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validName: Bool { !compactName.isEmpty && mkValidName(compactName) == compactName }
    private var validPIN: Bool { pin.count == 6 }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                onboardingHeader

                Group {
                    switch step {
                    case 0:
                        welcomeStep(geometry)
                    case 1:
                        nameStep(geometry)
                    default:
                        pinStep(geometry)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: 440, minHeight: geometry.size.height)
            .frame(maxWidth: .infinity)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .onAppear {
            setLastVersionDefault()
            profileCreated = chatModel.currentUser != nil
        }
        .alert("Unable to finish setup", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var onboardingHeader: some View {
        ZStack {
            HStack {
                if step > 0 && !isCompleting {
                    Button {
                        focusedField = nil
                        step -= 1
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 14, weight: .medium))
                            Text("Back")
                                .font(.system(size: 12, weight: .regular, design: .default))
                        }
                        .foregroundStyle(palette.muted)
                        .frame(minWidth: 82, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                } else {
                    Color.clear.frame(width: 82, height: 44)
                }

                Spacer()
            }

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(index == step ? palette.ink : palette.line)
                        .frame(width: index == step ? 18 : 5, height: 5)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step + 1) of 3")
        }
        .frame(height: 58)
        .padding(.horizontal, 22)
    }

    private func welcomeStep(_ geometry: GeometryProxy) -> some View {
        let compact = geometry.size.height < 700

        return VStack(spacing: 0) {
            Spacer()
                .frame(height: compact ? 42 : 72)

            VStack(spacing: 14) {
                Image("xauxat-mask")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(palette.ink)
                    .frame(width: compact ? 96 : 112,
                           height: compact ? 76 : 88)
                    .accessibilityHidden(true)

                Text(verbatim: "xauxat")
                    .font(.custom("Courier", size: compact ? 24 : 27).weight(.bold))
                    .tracking(2.7)
                    .foregroundStyle(palette.ink)
                    .accessibilityLabel("XauXat")
            }
            .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 0) {
                Text("This is ")
                    .font(.system(size: compact ? 21 : 23, weight: .medium))

                Text("your")
                    .font(.system(size: compact ? 21 : 23, weight: .bold))
                    .italic()

                Text(" space.")
                    .font(.system(size: compact ? 21 : 23, weight: .medium))
            }
            .foregroundStyle(palette.ink)
            .padding(.top, compact ? 38 : 50)

            Text("No phone number.\nNo email.\nNo global identity.")
                .font(.system(size: compact ? 13 : 14, weight: .regular, design: .default))
                .lineSpacing(compact ? 7 : 9)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.muted)
                .padding(.top, compact ? 20 : 26)

            Spacer(minLength: 26)

            VStack(spacing: compact ? 14 : 16) {
                Text("PRIVATE BY DEFAULT")
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .tracking(1.2)
                    .foregroundStyle(palette.muted)

                primaryButton("CONTINUE PRIVATELY", enabled: true) {
                    step = 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        focusedField = .displayName
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 71)
    }

    private func nameStep(_ geometry: GeometryProxy) -> some View {
        let compact = geometry.size.height < 700

        return VStack(spacing: 0) {
            Spacer()
                .frame(height: compact ? 48 : 78)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("What should")
                        .font(.system(size: compact ? 24 : 27, weight: .medium))

                    Text("")
                }

                HStack(spacing: 0) {
                    Text("people call")
                        .font(.system(size: compact ? 24 : 27, weight: .medium))

                    Text("you")
                        .font(.system(size: compact ? 24 : 27, weight: .bold))
                        .italic()
                        .padding(.leading, 8)

                    Text("?")
                        .font(.system(size: compact ? 24 : 27, weight: .medium))
                }
            }
            .foregroundStyle(palette.ink)
            .multilineTextAlignment(.center)

            TextField("Display name", text: $displayName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .displayName)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(palette.ink)
                .tint(palette.ink)
                .padding(.horizontal, 18)
                .frame(height: compact ? 54 : 58)
                .background(
                    palette.surface.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            validName || displayName.isEmpty
                                ? palette.line
                                : palette.danger,
                            lineWidth: 1
                        )
                }
                .padding(.top, compact ? 30 : 38)
                .submitLabel(.continue)
                .onSubmit {
                    if validName {
                        advanceToPIN()
                    }
                }
                .accessibilityLabel("Display name")

            Text(
                validName || displayName.isEmpty
                    ? "This doesn’t identify you.\nChange it whenever you want."
                    : "Use a name without unsupported characters."
            )
                .font(.system(size: compact ? 12 : 13, weight: .regular))
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .foregroundStyle(
                    validName || displayName.isEmpty
                        ? palette.muted
                        : palette.danger
                )
                .padding(.top, compact ? 20 : 24)

            Spacer(minLength: 24)

            primaryButton(
                "Continue",
                enabled: validName,
                action: advanceToPIN
            )
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 71)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                EmptyView()
            }
        }
    }

    private func pinStep(_ geometry: GeometryProxy) -> some View {
        let compact = geometry.size.height < 700

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Create ")
                    .font(.system(size: compact ? 24 : 27, weight: .medium))

                Text("your")
                    .font(.system(size: compact ? 24 : 27, weight: .bold))
                    .italic()

                Text(" PIN")
                    .font(.system(size: compact ? 24 : 27, weight: .medium))
            }
            .foregroundStyle(palette.ink)
            .padding(.top, compact ? 48 : 78)

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text("This will protect your")
                        .font(.system(size: compact ? 13 : 14, weight: .regular))

                    Text(verbatim: "xauxat")
                        .font(.custom("Courier", size: compact ? 13 : 14).weight(.bold))
                }

                Text("on this device.")
                    .font(.system(size: compact ? 13 : 14, weight: .regular))
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(palette.muted)
            .padding(.top, compact ? 24 : 44)

            ZStack {
                HStack(spacing: compact ? 16 : 20) {
                    ForEach(0..<6, id: \.self) { index in
                        Circle()
                            .fill(index < pin.count ? palette.ivory : Color.clear)
                            .overlay {
                                Circle().stroke(palette.ivory, lineWidth: 1)
                            }
                            .frame(width: 21, height: 21)
                    }
                }
                .accessibilityHidden(true)

                TextField("", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focusedField, equals: .pin)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .onChange(of: pin) { newValue in
                        let sanitized = String(newValue.filter(\.isNumber).prefix(6))
                        if pin != sanitized {
                            pin = sanitized
                        }
                    }
                    .accessibilityLabel("Six digit PIN")
            }
            .contentShape(Rectangle())
            .onTapGesture { focusedField = .pin }
            .padding(.top, compact ? 29 : 61)

            VStack(spacing: 0) {
                Image(systemName: "lock")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(palette.ink)

                VStack(spacing: 5) {
                    Text("Your PIN. Your responsibility.")
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))

                    Text("It never leaves your device.")
                        .font(.system(size: compact ? 12 : 13, weight: .regular))

                    Text("We can’t recover it.")
                        .font(.system(size: compact ? 12 : 13, weight: .regular))
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.muted)
                .padding(.top, compact ? 10 : 14)
            }
            .padding(.top, compact ? 31 : 48)

            Spacer(minLength: 18)

            primaryButton(
                isCompleting ? "Finishing…" : "Finish",
                enabled: validPIN && !isCompleting,
                action: finishOnboarding
            )


        }
        .padding(.horizontal, 22)
        .padding(.bottom, 71)
        .contentShape(Rectangle())
        .onTapGesture { focusedField = .pin }
    }

    private func primaryButton(_ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: label == "CONTINUE PRIVATELY" ? 13 : 16, weight: .semibold, design: .default))
                .tracking(0.2)
                .foregroundStyle(enabled ? palette.ivoryInk : palette.faint)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(enabled ? palette.ivory : palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func advanceToPIN() {
        focusedField = nil
        step = 2
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            focusedField = .pin
        }
    }

    private func finishOnboarding() {
        guard validName, validPIN, !isCompleting else { return }
        focusedField = nil
        isCompleting = true

        do {
            if !profileCreated {
                AppChatState.shared.set(.active)
                chatModel.currentUser = try apiCreateActiveUser(Profile(displayName: compactName, fullName: ""))
                profileCreated = true
                UserDefaults.standard.set(false, forKey: DEFAULT_PRIVACY_SHOW_FILE_ENCRYPTION)
                try startChat(onboarding: true)
            }

            guard kcAppPassword.set(pin) else {
                throw RuntimeError("The device Keychain did not save the XauXat PIN")
            }
            privacyLocalAuthModeDefault.set(.passcode)
            appLocalAuthEnabledGroupDefault.set(true)
            UserDefaults.standard.set(true, forKey: DEFAULT_PERFORM_LA)
            UserDefaults.standard.set(true, forKey: DEFAULT_LA_NOTICE_SHOWN)
            chatModel.contentViewAccessAuthenticated = true

            applySimpleXOnboardingDefaults()
        } catch {
            isCompleting = false
            errorMessage = responseError(error)
        }
    }

    private func applySimpleXOnboardingDefaults() {
        applyDefaultNotificationMode()
        let selectedOperatorIds = Set(chatModel.conditions.serverOperators.filter(\.enabled).map(\.operatorId))
        Task {
            do {
                var updatedConditions = chatModel.conditions
                if !selectedOperatorIds.isEmpty {
                    updatedConditions = try await acceptConditions(
                        conditionsId: chatModel.conditions.currentConditions.conditionsId,
                        operatorIds: Array(selectedOperatorIds)
                    )
                    if let operators = xauXatEnabledOperators(updatedConditions.serverOperators, selectedOperatorIds: selectedOperatorIds) {
                        updatedConditions = try await setServerOperators(operators: operators)
                    }
                }

                await MainActor.run {
                    chatModel.conditions = updatedConditions
                    onboardingStageDefault.set(.onboardingComplete)
                    dismissAllSheets(animated: false) {
                        DispatchQueue.main.async {
                            chatModel.onboardingStage = .onboardingComplete
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isCompleting = false
                    errorMessage = responseError(error)
                }
            }
        }
    }

    private func applyDefaultNotificationMode() {
        xauXatSetNotificationModeIntent(.instant)
        chatModel.notificationMode = .instant
        reconcileXauXatNotificationRegistration(token: chatModel.deviceToken)
    }
}

private func xauXatEnabledOperators(_ operators: [ServerOperator], selectedOperatorIds: Set<Int64>) -> [ServerOperator]? {
    var operators = operators
    guard !operators.isEmpty else { return nil }

    for index in operators.indices {
        operators[index].enabled = selectedOperatorIds.contains(operators[index].operatorId)
    }

    let hasSMPStorage = operators.contains { $0.enabled && $0.smpRoles.storage }
    let hasSMPProxy = operators.contains { $0.enabled && $0.smpRoles.proxy }
    let hasXFTPStorage = operators.contains { $0.enabled && $0.xftpRoles.storage }
    let hasXFTPProxy = operators.contains { $0.enabled && $0.xftpRoles.proxy }

    if hasSMPStorage && hasSMPProxy && hasXFTPStorage && hasXFTPProxy {
        return operators
    }

    guard let firstEnabledIndex = operators.firstIndex(where: \.enabled) else { return nil }
    if !hasSMPStorage { operators[firstEnabledIndex].smpRoles.storage = true }
    if !hasSMPProxy { operators[firstEnabledIndex].smpRoles.proxy = true }
    if !hasXFTPStorage { operators[firstEnabledIndex].xftpRoles.storage = true }
    if !hasXFTPProxy { operators[firstEnabledIndex].xftpRoles.proxy = true }
    return operators
}

struct XauXatHomeView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var activeUserPickerSheet: UserPickerSheet?

    @State private var tab: XauXatTab = .chats
    @State private var showNewChatSheet = false
    @State private var parentSheet: SomeSheet<AnyView>?
    @State private var scrollToItemId: ChatItem.ID?
    @StateObject private var chatTagsModel = ChatTagsModel.shared

    private var palette: XauXatPalette { XauXatPalette(colorScheme) }

    var body: some View {
        NavStackCompat(
            isActive: Binding(
                get: { chatModel.chatId != nil },
                set: { if !$0 { chatModel.chatId = nil } }
            ),
            destination: chatView
        ) {
            VStack(spacing: 0) {
                XauXatHeader(
                    palette: palette,
                    action: (tab == .settings || tab == .notes)
                        ? nil
                        : { showNewChatSheet = true }
                )

                Group {
                    switch tab {
                    case .chats:
                        XauXatChatsView(
                            palette: palette,
                            parentSheet: $parentSheet,
                            showNewChatSheet: $showNewChatSheet
                        )
                    case .contacts:
                        XauXatContactsView(
                            palette: palette,
                            parentSheet: $parentSheet,
                            showNewChatSheet: $showNewChatSheet
                        )
                    case .notes:
                        XauXatNotesView(
                            palette: palette
                        )
                    case .settings:
                        XauXatSettingsHome(
                            palette: palette,
                            activeUserPickerSheet: $activeUserPickerSheet
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                XauXatBottomNavigation(palette: palette, selection: $tab)
            }
            .background(palette.background.ignoresSafeArea())
            .navigationBarHidden(true)
        }
        .appSheet(isPresented: $showNewChatSheet) {
            XauXatNewChatSheet(palette: palette)
        }
        .appSheet(
            item: $activeUserPickerSheet,
            onDismiss: { chatModel.laRequest = nil },
            content: { UserPickerSheetView(sheet: $0) }
        )
        .sheet(item: $parentSheet) { sheet in
            if #available(iOS 16.0, *) {
                sheet.content.presentationDetents([.fraction(sheet.fraction)])
            } else {
                sheet.content
            }
        }
        .environmentObject(chatTagsModel)
    }

    @ViewBuilder private func chatView() -> some View {
        if let chatId = chatModel.chatId, let chat = chatModel.getChat(chatId) {
            let itemsModel = ItemsModel.shared
            ChatView(
                chat: chat,
                im: itemsModel,
                mergedItems: BoxedValue(MergedItems.create(itemsModel, [])),
                floatingButtonModel: FloatingButtonModel(im: itemsModel),
                scrollToItemId: $scrollToItemId
            )
        }
    }
}

private struct XauXatHeader: View {
    let palette: XauXatPalette
    let action: (() -> Void)?

    var body: some View {
        HStack {
            Spacer()

            if let action {
                Button(action: action) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.ivoryInk)
                        .frame(width: 32, height: 32)
                        .background(palette.ivory, in: Circle())
                }
                .buttonStyle(.plain)
                .offset(y: 7)
                .accessibilityLabel("New conversation")
            }
        }
        .frame(height: 38)
        .padding(.horizontal, 22)
        .background(palette.background)
    }
}

private struct XauXatChatsView: View {
    @EnvironmentObject private var chatModel: ChatModel
    let palette: XauXatPalette
    @Binding var parentSheet: SomeSheet<AnyView>?
    @Binding var showNewChatSheet: Bool

    @State private var searchText = ""
    @State private var searchRevealed = false
    @State private var pullDistance: CGFloat = 0

    private var chats: [Chat] {
        let availableChats = chatModel.chats.filter { chat in
            guard !chat.chatInfo.chatDeleted,
                  !chat.chatInfo.contactCard,
                  !xauXatIsChatHidden(chat.id) else {
                return false
            }

            if case .local = chat.chatInfo {
                return false
            }

            return true
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            return availableChats
        }

        return availableChats.filter {
            $0.chatInfo.chatViewName.localizedCaseInsensitiveContains(query)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(palette.muted)

            TextField("Search conversations", text: $searchText)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(palette.ink)
                .tint(palette.ink)
                .autocorrectionDisabled()

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(
            palette.surface,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Chats")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, searchRevealed ? 18 : 6)

            if searchRevealed {
                searchBar
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
            }

            if chats.isEmpty && searchText.isEmpty {
                XauXatEmptyState(
                    palette: palette,
                    title: "No conversations yet.",
                    subtitle: "Your private space starts here.",
                    action: { showNewChatSheet = true }
                )
                .contentShape(Rectangle())
                .gesture(pullGesture)
            } else if chats.isEmpty {
                VStack(spacing: 8) {
                    Text("No results")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.ink)

                    Text("No conversations match your search.")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(palette.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 42)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(chats, id: \.viewId) { chat in
                            XauXatChatDestination(
                                chat: chat,
                                palette: palette,
                                parentSheet: $parentSheet,
                                contactStyle: false
                            )
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .simultaneousGesture(pullGesture)
                .refreshable {
                    try? await reconnectAllServers()
                }
            }
        }
    }

    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !searchRevealed else { return }

                pullDistance = max(0, value.translation.height)

                if pullDistance >= 38 {
                    withAnimation(.easeOut(duration: 0.20)) {
                        searchRevealed = true
                    }
                }
            }
            .onEnded { _ in
                pullDistance = 0
            }
    }
}

private struct XauXatNotesView: View {
    @EnvironmentObject private var chatModel: ChatModel
    let palette: XauXatPalette

    private var privateNotes: Chat? {
        chatModel.chats.first { chat in
            guard !chat.chatInfo.chatDeleted else { return false }
            if case let .local(noteFolder) = chat.chatInfo {
                return noteFolder.ready
            }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Notes")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 18)

            if let privateNotes {
                Button {
                    ItemsModel.shared.loadOpenChat(privateNotes.id)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "lock.doc")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(palette.ivoryInk)
                            .frame(width: 50, height: 50)
                            .background(palette.ivory, in: Circle())

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Private notes")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(palette.ink)

                            Text("Only you can access these notes.")
                                .font(.system(size: 13.5, weight: .regular))
                                .foregroundStyle(palette.muted)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.faint)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(chatModel.chatRunning != true)
                .padding(.horizontal, 22)

                Spacer()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "lock.doc")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(palette.muted)

                    Text("Private notes unavailable")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.ink)

                    Text("Your private notes are not ready yet.")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct XauXatContactsView: View {
    @EnvironmentObject private var chatModel: ChatModel
    let palette: XauXatPalette
    @Binding var parentSheet: SomeSheet<AnyView>?
    @Binding var showNewChatSheet: Bool
    @State private var searchText = ""

    private var contacts: [Chat] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return chatModel.chats.filter { chat in
            guard case let .direct(contact) = chat.chatInfo,
                  contact.active,
                  !contact.chatDeleted,
                  !contact.isContactCard,
                  !xauXatIsChatLocked(chat.id),
                  !xauXatIsChatHidden(chat.id) else { return false }
            return query.isEmpty || contact.chatViewName.localizedLowercase.contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(palette.faint)
                TextField("Search contacts", text: $searchText)
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundStyle(palette.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 22)
            .padding(.top, 8)

            if contacts.isEmpty {
                XauXatEmptyState(
                    palette: palette,
                    title: searchText.isEmpty ? "No contacts yet." : "No matching contacts.",
                    subtitle: searchText.isEmpty ? "Create a private link to connect." : "Try a different name.",
                    action: searchText.isEmpty ? { showNewChatSheet = true } : nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(contacts, id: \.viewId) { chat in
                            XauXatChatDestination(
                                chat: chat,
                                palette: palette,
                                parentSheet: $parentSheet,
                                contactStyle: true
                            )
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                }
            }
        }
    }
}

private struct XauXatChatDestination: View {
    @EnvironmentObject private var chatModel: ChatModel
    @ObservedObject var chat: Chat
    let palette: XauXatPalette
    @Binding var parentSheet: SomeSheet<AnyView>?
    let contactStyle: Bool

    var body: some View {
        switch chat.chatInfo {
        case let .direct(contact) where contact.active && !contact.isContactCard:
            destination
        case .group, .local:
            destination
        default:
            ChatListNavLink(chat: chat, parentSheet: $parentSheet)
                .frame(minHeight: 76)
        }
    }

    private var destination: some View {
        Button {
            ItemsModel.shared.loadOpenChat(chat.id)
        } label: {
            XauXatChatRow(chat: chat, palette: palette, contactStyle: contactStyle)
        }
        .buttonStyle(.plain)
        .disabled(chatModel.chatRunning != true || chatModel.deletedChats.contains(chat.id))
    }
}

private struct XauXatChatRow: View {
    @ObservedObject var chat: Chat
    let palette: XauXatPalette
    let contactStyle: Bool

    private var timestamp: Date {
        chat.chatItems.last?.meta.itemTs ?? chat.chatInfo.chatTs
    }

    private var detail: String {
        if xauXatIsChatLocked(chat.id) {
            return "Locked conversation"
        }
        if contactStyle {
            return chat.chatInfo.shortDescr?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "No bio info"
        }
        return chat.chatItems.last?.text(isChannel: chat.chatInfo.isChannel).nonEmpty ?? "No messages yet"
    }

    var body: some View {
        HStack(spacing: 14) {
            ChatInfoImage(
                chat: chat,
                size: 50,
                color: palette.raised,
                radiusOverride: 50
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(chat.chatInfo.chatViewName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)

                    Spacer(minLength: 10)

                    if !contactStyle {
                        formatTimestampText(timestamp)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(palette.faint)
                    }
                }

                HStack(spacing: 7) {
                    if xauXatIsChatLocked(chat.id) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.faint)
                    }

                    Text(detail)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                        .privacySensitive(!contactStyle)

                    Spacer(minLength: 8)

                    if contactStyle {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.faint)
                    } else if chat.chatStats.unreadCount > 0 {
                        Text(verbatim: "\(chat.chatStats.unreadCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.ivoryInk)
                            .frame(minWidth: 21, minHeight: 21)
                            .background(palette.ivory, in: Circle())
                    }
                }
            }
            .offset(y: 1)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.line.opacity(0.40))
                .frame(height: 0.5)
                .padding(.leading, 64)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this conversation")
    }
}

private struct XauXatEmptyState: View {
    let palette: XauXatPalette
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 9) {
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .default))
                .foregroundStyle(palette.ink)
            Text(subtitle)
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
            if let action {
                Button(action: action) {
                    Text("Start a conversation")
                        .font(.system(size: 14, weight: .bold, design: .default))
                        .foregroundStyle(palette.ivoryInk)
                        .frame(maxWidth: 250, minHeight: 52)
                        .background(palette.ivory)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .padding(.top, 18)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct XauXatSettingsHome: View {
    @EnvironmentObject private var chatModel: ChatModel
    @EnvironmentObject private var plusEntitlements: XauXatPlusEntitlements
    let palette: XauXatPalette
    @Binding var activeUserPickerSheet: UserPickerSheet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let user = chatModel.currentUser {
                    Button { activeUserPickerSheet = .currentProfile } label: {
                        HStack(spacing: 14) {
                            ProfileImage(imageStr: user.image, size: 64, color: palette.raised)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(user.displayName)
                                    .font(.system(size: 18, weight: .bold, design: .default))
                                    .foregroundStyle(palette.ink)
                                    .lineLimit(1)
                                Text(user.shortDescr?.nonEmpty ?? "Your private identity")
                                    .font(.system(size: 13, weight: .regular, design: .default))
                                    .foregroundStyle(palette.muted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                                .foregroundStyle(palette.faint)
                        }
                        .padding(16)
                        .background(palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open your profile")
                }

                XauXatSectionTitle("PLAN", palette: palette)
                    .padding(.top, 26)
                XauXatSettingsCard(palette: palette) {
                    NavigationLink {
                        XauXatPlusView()
                            .navigationTitle("XauXat Plus")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        XauXatSettingsRow(
                            palette: palette,
                            symbol: "plus.circle",
                            title: "XauXat Plus",
                            value: plusStatusLabel
                        )
                    }
                    .accessibilityHint("View subscription details, subscribe, or restore purchases")
                }

                XauXatSectionTitle("APP", palette: palette)
                    .padding(.top, 26)
                XauXatSettingsCard(palette: palette) {
                    if canCreateIdentities || chatModel.users.count > 1 {
                        NavigationLink {
                            UserProfilesView(
                                allowsProfileCreation: canCreateIdentities,
                                creationLockedByPlan: !canCreateIdentities,
                                title: "XauXat identities"
                            )
                        } label: {
                            XauXatSettingsRow(
                                palette: palette,
                                symbol: "person.2",
                                title: "Identities",
                                value: identitiesStatusLabel
                            )
                        }
                        .accessibilityHint(canCreateIdentities
                            ? "Create, switch and protect separate XauXat identities"
                            : "Manage existing identities; creating new identities requires XauXat Plus")
                    } else {
                        NavigationLink {
                            XauXatPlusView()
                                .navigationTitle("XauXat Plus")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            XauXatSettingsRow(
                                palette: palette,
                                symbol: "person.2",
                                title: "Identities",
                                value: "Plus"
                            )
                        }
                        .accessibilityHint("Unlock multiple separate identities with XauXat Plus")
                    }
                    NavigationLink {
                        XauXatPrivacyView()
                    } label: {
                        XauXatSettingsRow(palette: palette, symbol: "lock", title: "Privacy & Security")
                    }
                    NavigationLink {
                        XauXatNotificationsView()
                    } label: {
                        XauXatSettingsRow(palette: palette, symbol: "bell", title: "Notifications")
                    }
                    NavigationLink {
                        XauXatAppearanceView()
                    } label: {
                        XauXatSettingsRow(palette: palette, symbol: "paintpalette", title: "Appearance")
                    }
                    Button { activeUserPickerSheet = .useFromDesktop } label: {
                        XauXatSettingsRow(palette: palette, symbol: "desktopcomputer", title: "Devices")
                    }
                }

                XauXatSectionTitle("CONNECTION", palette: palette)
                    .padding(.top, 26)
                XauXatSettingsCard(palette: palette) {
                    NavigationLink {
                        XauXatTorDiagnosticsView()
                    } label: {
                        XauXatSettingsRow(
                            palette: palette,
                            symbol: "network",
                            title: "Private connection",
                            value: isXauXatManagedTorConfig(getNetCfg()) ? "Tor active" : "Checking"
                        )
                    }
                }

                XauXatSectionTitle("SUPPORT", palette: palette)
                    .padding(.top, 26)
                XauXatSettingsCard(palette: palette) {
                    NavigationLink {
                        XauXatHelpDestination()
                            .navigationTitle("XauXat support")
                            .modifier(ThemedBackground())
                    } label: {
                        XauXatSettingsRow(palette: palette, symbol: "questionmark.circle", title: "Help & Support")
                    }
                    NavigationLink {
                        XauXatAboutView()
                    } label: {
                        XauXatSettingsRow(
                            palette: palette,
                            symbol: "info.circle",
                            title: "About XauXat",
                            value: appVersion.map { "v\($0)" }
                        )
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .buttonStyle(.plain)
    }

    private var plusStatusLabel: String {
        if plusEntitlements.hasIncludedAccess { return "Included" }
        switch plusEntitlements.status {
        case .active: return "Active"
        case .checking: return "Checking"
        case .notPurchased, .expired, .revoked, .unverified, .unavailable: return "Free"
        }
    }

    private var canCreateIdentities: Bool {
        plusEntitlements.isAuthorized(for: .multipleIdentities)
    }

    private var identitiesStatusLabel: String {
        canCreateIdentities ? "\(chatModel.users.count)" : "Existing"
    }
}

private struct XauXatHelpDestination: View {
    @Environment(\.colorScheme) private var colorScheme

    private var palette: XauXatPalette { XauXatPalette(colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Help with XauXat")
                    .font(.system(size: 26, weight: .bold, design: .default))
                    .foregroundStyle(palette.ink)
                    .padding(.bottom, 8)

                Text("Create private connections, exchange messages and keep your local data under your control.")
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 30)

                XauXatSectionTitle("START A CONVERSATION", palette: palette)
                XauXatHelpCard(palette: palette) {
                    XauXatHelpStep(
                        palette: palette,
                        number: "01",
                        title: "Open the + menu",
                        detail: "Use the button at the top of Chats or Contacts."
                    )
                    XauXatHelpStep(
                        palette: palette,
                        number: "02",
                        title: "Choose how to connect",
                        detail: "Start a conversation, create a private link, or scan a QR code."
                    )
                    XauXatHelpStep(
                        palette: palette,
                        number: "03",
                        title: "Share privately",
                        detail: "Only send invitation links and QR codes to people you intend to connect with."
                    )
                }

                XauXatSectionTitle("MESSAGE FORMATTING", palette: palette)
                    .padding(.top, 28)
                XauXatHelpCard(palette: palette) {
                    MarkdownHelp()
                        .foregroundStyle(palette.ink)
                        .padding(16)
                }

                XauXatSectionTitle("BETA SUPPORT", palette: palette)
                    .padding(.top, 28)
                XauXatHelpCard(palette: palette) {
                    Text("For beta support, open XauXat in TestFlight and choose Send Beta Feedback.")
                        .font(.system(size: 13, weight: .regular, design: .default))
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                }
            }
            .padding(22)
        }
        .background(palette.background.ignoresSafeArea())
    }
}

private struct XauXatHelpCard<Content: View>: View {
    let palette: XauXatPalette
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct XauXatHelpStep: View {
    let palette: XauXatPalette
    let number: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .default))
                .foregroundStyle(palette.muted)
                .frame(width: 24, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .default))
                    .foregroundStyle(palette.ink)
                Text(detail)
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct XauXatPrivacyView: View {
    @EnvironmentObject private var plusEntitlements: XauXatPlusEntitlements
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(DEFAULT_PERFORM_LA) private var appLock = false
    @State private var localAuthMode = privacyLocalAuthModeDefault.get()
    @State private var showHiddenConversations = false

    private var palette: XauXatPalette { XauXatPalette(colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                XauXatSectionTitle("DEVICE", palette: palette)
                XauXatSettingsCard(palette: palette) {
                    NavigationLink {
                        SimplexLockView(prefPerformLA: $appLock, currentLAMode: $localAuthMode)
                            .navigationTitle("App Lock")
                            .modifier(ThemedBackground(grouped: true))
                    } label: {
                        XauXatSettingsRow(
                            palette: palette,
                            symbol: appLock ? "lock.fill" : "lock",
                            title: "App Lock",
                            value: appLock ? (localAuthMode == .system ? "System" : "Passcode") : "Off"
                        )
                    }
                    if canManageHiddenConversations {
                        Button {
                            authenticate(
                                title: "Hidden conversations",
                                reason: NSLocalizedString("Authenticate to manage hidden conversations", comment: "hidden conversations")
                            ) { result in
                                if case .success = result { showHiddenConversations = true }
                            }
                        } label: {
                            XauXatSettingsRow(
                                palette: palette,
                                symbol: "eye.slash",
                                title: "Hidden conversations"
                            )
                        }
                        .background {
                            NavigationLink(
                                destination: XauXatHiddenChatsView(),
                                isActive: $showHiddenConversations,
                                label: { EmptyView() }
                            )
                            .hidden()
                        }
                    } else {
                        NavigationLink {
                            XauXatPlusView()
                                .navigationTitle("XauXat Plus")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            XauXatSettingsRow(
                                palette: palette,
                                symbol: "eye.slash",
                                title: "Hidden conversations",
                                value: "Plus"
                            )
                        }
                    }
                    if canManageProtectedProfiles {
                        NavigationLink {
                            UserProfilesView(
                                allowsProfileCreation: false,
                                title: "Protected profiles"
                            )
                        } label: {
                            XauXatSettingsRow(
                                palette: palette,
                                symbol: "person.crop.circle.badge.checkmark",
                                title: "Protected profiles"
                            )
                        }
                    } else {
                        NavigationLink {
                            XauXatPlusView()
                                .navigationTitle("XauXat Plus")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            XauXatSettingsRow(
                                palette: palette,
                                symbol: "person.crop.circle.badge.checkmark",
                                title: "Protected profiles",
                                value: "Plus"
                            )
                        }
                    }
                }

                Text("XauXat always hides its content in the App Switcher. Your security settings stay on this device.")
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 5)
                    .padding(.top, 18)
            }
            .padding(22)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
        .buttonStyle(.plain)
    }

    private var canManageHiddenConversations: Bool {
        plusEntitlements.isAuthorized(for: .hiddenChats)
    }

    private var canManageProtectedProfiles: Bool {
        plusEntitlements.isAuthorized(for: .protectedProfiles)
    }
}

private struct XauXatHiddenChatsView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var hiddenIDs = xauXatHiddenChatIDs()

    private var palette: XauXatPalette { XauXatPalette(colorScheme) }
    private var chats: [Chat] {
        chatModel.chats.filter { hiddenIDs.contains($0.id) && !$0.chatInfo.chatDeleted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if chats.isEmpty {
                    Text("No hidden conversations.")
                        .font(.system(size: 14, weight: .regular, design: .default))
                        .foregroundStyle(palette.muted)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    XauXatSettingsCard(palette: palette) {
                        ForEach(chats, id: \.viewId) { chat in
                            Button {
                                if chatModel.setXauXatChatHidden(chat.id, hidden: false) {
                                    hiddenIDs.remove(chat.id)
                                }
                            } label: {
                                HStack(spacing: 13) {
                                    ChatInfoImage(chat: chat, size: 42, color: palette.raised)
                                    Text(chat.chatInfo.chatViewName)
                                        .font(.system(size: 14, weight: .bold, design: .default))
                                        .foregroundStyle(palette.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 12)
                                    Text("Show")
                                        .font(.system(size: 12, weight: .bold, design: .default))
                                        .foregroundStyle(palette.muted)
                                }
                                .padding(.horizontal, 16)
                                .frame(minHeight: 64)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text("Showing a conversation returns it to the normal list without deleting messages or changing the contact.")
                        .font(.system(size: 11, weight: .regular, design: .default))
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 5)
                        .padding(.top, 18)
                }
            }
            .padding(22)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("Hidden conversations")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct XauXatNotificationsView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var mode = ChatModel.shared.notificationMode
    @State private var errorMessage: String?

    private var palette: XauXatPalette { XauXatPalette(colorScheme) }
    private let modes: [NotificationsMode] = [.instant, .periodic, .off]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                XauXatSectionTitle("DELIVERY", palette: palette)
                XauXatSettingsCard(palette: palette) {
                    ForEach(modes, id: \.self) { candidate in
                        Button { update(candidate) } label: {
                            XauXatSelectionRow(
                                palette: palette,
                                title: candidate.label,
                                subtitle: ntfModeShortDescription(candidate),
                                selected: mode == candidate
                            )
                        }
                        .disabled(chatModel.notificationRegistrationInFlight)
                    }
                }

                Text("Notification content remains end-to-end encrypted. You can control lock-screen previews in iOS Settings.")
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 5)
                    .padding(.top, 18)

                Text(registrationStatus)
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundStyle(errorMessage == nil ? palette.muted : palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 5)
                    .padding(.top, 10)
            }
            .padding(22)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .buttonStyle(.plain)
        .overlay {
            if chatModel.notificationRegistrationInFlight {
                ProgressView()
                    .tint(palette.ivory)
            }
        }
        .onAppear {
            (chatModel.savedToken, chatModel.tokenStatus, chatModel.notificationMode, chatModel.notificationServer) = apiGetNtfToken()
            xauXatMigrateNotificationModeIntentIfNeeded(chatModel.notificationMode)
            mode = xauXatNotificationModeIntent() ?? chatModel.notificationMode
            reconcileXauXatNotificationRegistration(token: chatModel.deviceToken)
        }
        .onChange(of: chatModel.notificationRegistrationInFlight) { inFlight in
            if !inFlight {
                mode = xauXatNotificationModeIntent() ?? chatModel.notificationMode
                errorMessage = chatModel.notificationRegistrationError
            }
        }
        .alert("Notification error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func update(_ newMode: NotificationsMode) {
        guard newMode != mode else { return }
        xauXatSetNotificationModeIntent(newMode)
        mode = newMode
        chatModel.notificationMode = newMode
        chatModel.notificationRegistrationError = nil
        errorMessage = nil
        reconcileXauXatNotificationRegistration(token: chatModel.deviceToken)
    }

    private var registrationStatus: String {
        if let errorMessage { return "Registration failed: \(errorMessage)" }
        if chatModel.notificationRegistrationInFlight { return "Updating notification registration…" }
        if mode == .off { return "Notifications are off." }
        if chatModel.deviceToken == nil { return "Waiting for an APNs token from iOS. This choice will be applied automatically." }
        if let status = chatModel.tokenStatus { return "APNs token status: \(status.text)." }
        return "Waiting for notification registration."
    }
}

private enum XauXatThemeMode: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    var id: Self { self }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    static var current: Self {
        switch currentThemeDefault.get() {
        case DefaultTheme.SYSTEM_THEME_NAME: .system
        case DefaultTheme.LIGHT.themeName: .light
        default: .dark
        }
    }
}

private struct XauXatAppearanceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection = XauXatThemeMode.current

    private var palette: XauXatPalette { XauXatPalette(colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                XauXatSectionTitle("THEME", palette: palette)
                HStack(spacing: 8) {
                    ForEach(XauXatThemeMode.allCases) { mode in
                        Button { apply(mode) } label: {
                            VStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Capsule()
                                        .fill(mode == .light ? Color(red: 200 / 255, green: 195 / 255, blue: 187 / 255) : Color(red: 52 / 255, green: 52 / 255, blue: 52 / 255))
                                        .frame(width: 54, height: 10)
                                    Capsule()
                                        .fill(mode == .light ? Color(red: 217 / 255, green: 212 / 255, blue: 204 / 255) : Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255))
                                        .frame(width: 42, height: 10)
                                }
                                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                                .padding(9)
                                .background(mode == .light ? Color(red: 238 / 255, green: 234 / 255, blue: 227 / 255) : .black)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                Text(mode.label)
                                    .font(.system(size: 10, weight: .regular, design: .default))
                                    .foregroundStyle(palette.ink)
                            }
                            .padding(7)
                            .background(palette.surface)
                            .overlay {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .stroke(selection == mode ? palette.ivory : palette.line, lineWidth: selection == mode ? 2 : 1)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }
                        .accessibilityLabel("\(mode.label) theme")
                        .accessibilityAddTraits(selection == mode ? .isSelected : [])
                    }
                }

                Text("XauXat keeps the same private, low-contrast palette across light and dark mode.")
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 5)
                    .padding(.top, 18)
            }
            .padding(22)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .buttonStyle(.plain)
    }

    private func apply(_ mode: XauXatThemeMode) {
        selection = mode
        switch mode {
        case .system: ThemeManager.applyTheme(DefaultTheme.SYSTEM_THEME_NAME)
        case .light: ThemeManager.applyTheme(DefaultTheme.LIGHT.themeName)
        case .dark: ThemeManager.applyTheme(DefaultTheme.BLACK.themeName)
        }
    }
}

private struct XauXatAboutView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var coreVersion: CoreVersionInfo?

    private var palette: XauXatPalette { XauXatPalette(colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 3) {
                    Text(verbatim: "xauxat")
                        .font(.custom("Courier", size: 27).weight(.bold))
                        .tracking(2.7)
                    Text(verbatim: "X -- X")
                        .font(.system(size: 16, weight: .bold, design: .default))
                        .tracking(2)
                }
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 42)

                XauXatSettingsCard(palette: palette) {
                    XauXatValueRow(palette: palette, title: "App version", value: appVersion.map { "v\($0)" } ?? "Unknown")
                    XauXatValueRow(palette: palette, title: "Build", value: appBuild ?? "Unknown")
                    if let coreVersion {
                        XauXatValueRow(palette: palette, title: "Messaging core", value: "v\(coreVersion.version)")
                    }
                }
            }
            .padding(22)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("About XauXat")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { coreVersion = try? apiGetVersion() }
    }
}

private struct XauXatSectionTitle: View {
    let title: LocalizedStringKey
    let palette: XauXatPalette

    init(_ title: LocalizedStringKey, palette: XauXatPalette) {
        self.title = title
        self.palette = palette
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .default))
            .foregroundStyle(palette.muted)
            .padding(.leading, 5)
            .padding(.bottom, 8)
    }
}

private struct XauXatSettingsCard<Content: View>: View {
    let palette: XauXatPalette
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct XauXatSettingsRow: View {
    let palette: XauXatPalette
    let symbol: String
    let title: LocalizedStringKey
    var value: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(palette.muted)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundStyle(palette.ink)
            Spacer()
            if let value {
                Text(value)
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundStyle(palette.muted)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.faint)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 59)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.line)
                .frame(height: 1)
                .padding(.leading, 54)
        }
        .contentShape(Rectangle())
    }
}

private struct XauXatToggleRow: View {
    let palette: XauXatPalette
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(palette.muted)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .regular, design: .default))
                        .foregroundStyle(palette.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10, weight: .regular, design: .default))
                            .foregroundStyle(palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .tint(palette.ivory)
        .padding(.horizontal, 16)
        .frame(minHeight: 66)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.line).frame(height: 1).padding(.leading, 54)
        }
    }
}

private struct XauXatSelectionRow: View {
    let palette: XauXatPalette
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let selected: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundStyle(palette.ink)
                Text(subtitle)
                    .font(.system(size: 10, weight: .regular, design: .default))
                    .foregroundStyle(palette.muted)
            }
            Spacer(minLength: 12)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(selected ? palette.success : palette.faint)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 66)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.line).frame(height: 1).padding(.leading, 16)
        }
    }
}

private struct XauXatValueRow: View {
    let palette: XauXatPalette
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundStyle(palette.ink)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .default))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 59)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.line).frame(height: 1).padding(.leading, 16)
        }
    }
}

private struct XauXatBottomNavigation: View {
    let palette: XauXatPalette
    @Binding var selection: XauXatTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(XauXatTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    let selected = selection == tab

                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(
                                size: 22,
                                weight: selected ? .semibold : .regular
                            ))
                            .frame(height: 25)

                        Text(tab.title)
                            .font(.system(
                                size: 11,
                                weight: selected ? .semibold : .regular
                            ))
                    }
                    .foregroundStyle(
                        selected ? palette.ink : palette.muted
                    )
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(
                    selection == tab ? .isSelected : []
                )
            }
        }
        .padding(.top, 3)
        .background(palette.background)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.line.opacity(0.65))
                .frame(height: 0.5)
        }
    }
}

private struct XauXatNewChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    let palette: XauXatPalette

    var body: some View {
        NavigationView {
            VStack {
                Spacer(minLength: 20)
                XauXatSettingsCard(palette: palette) {
                    NavigationLink {
                        NewChatView(selection: .connect)
                            .modifier(ThemedBackground(grouped: true))
                    } label: {
                        XauXatSettingsRow(
                            palette: palette,
                            symbol: "bubble.left",
                            title: "New conversation",
                            value: "Private chat"
                        )
                    }
                    NavigationLink {
                        NewChatView(selection: .invite)
                            .modifier(ThemedBackground(grouped: true))
                    } label: {
                        XauXatSettingsRow(
                            palette: palette,
                            symbol: "link",
                            title: "Create private link",
                            value: "Share to connect"
                        )
                    }
                    NavigationLink {
                        NewChatView(selection: .connect, showQRCodeScanner: true)
                            .modifier(ThemedBackground(grouped: true))
                    } label: {
                        XauXatSettingsRow(
                            palette: palette,
                            symbol: "qrcode.viewfinder",
                            title: "Scan QR code",
                            value: "Connect instantly"
                        )
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .background(palette.background.ignoresSafeArea())
            .navigationTitle("New conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(palette.ink)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }
}

struct XauXatTorDiagnosticsView: View {
    @ObservedObject private var tor = EmbeddedTorManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var verification: Verification = .idle

    private enum Verification: Equatable {
        case idle
        case checking
        case verified
        case failed(String)
    }

    private var palette: XauXatPalette { XauXatPalette(colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Tor is built into XauXat. Messages stay disabled until its local route is ready.")
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                XauXatSettingsCard(palette: palette) {
                    statusRow("Embedded Tor", value: torState)
                    statusRow("Messaging route", value: routeState)
                    statusRow("Tor route probe", value: verificationState)
                }

                Button {
                    Task { await verify() }
                } label: {
                    HStack(spacing: 10) {
                        if verification == .checking {
                            ProgressView().tint(palette.ivoryInk)
                        }
                            Text(verification == .checking ? "Checking through Tor" : "Verify Tor route")
                            .font(.system(size: 14, weight: .bold, design: .default))
                    }
                    .foregroundStyle(palette.ivoryInk)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(palette.ivory)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .disabled(verification == .checking || !isXauXatManagedTorConfig(getNetCfg()))

                if case let .failed(message) = verification {
                    Text(message)
                        .font(.system(size: 12, weight: .regular, design: .default))
                        .foregroundStyle(palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("This check sends no chat data. It opens a fresh SOCKS5 tunnel through the same local Tor endpoint and confirms that Tor Project is reachable through it. It does not request, display or store an exit IP.")
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("Private connection")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statusRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundStyle(palette.ink)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .default))
                .foregroundStyle(value == "Ready" || value == "Forced through Tor" || value == "Passed" ? palette.success : palette.muted)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 59)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.line).frame(height: 1).padding(.leading, 16)
        }
    }

    private var torState: String {
        switch tor.state {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case let .bootstrapping(progress): "\(progress)%"
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }

    private var routeState: String {
        isXauXatManagedTorConfig(getNetCfg()) ? "Forced through Tor" : "Not ready"
    }

    private var verificationState: String {
        switch verification {
        case .idle: "Not run"
        case .checking: "Checking"
        case .verified: "Passed"
        case .failed: "Failed"
        }
    }

    @MainActor private func verify() async {
        verification = .checking
        do {
            verification = try await tor.verifyTorRoute()
                ? .verified
                : .failed("The route probe could not confirm the managed Tor tunnel. Messaging remains fail-closed, but this build must not be distributed.")
        } catch {
            verification = .failed(error.localizedDescription)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
