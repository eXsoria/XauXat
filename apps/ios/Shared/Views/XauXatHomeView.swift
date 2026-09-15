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
    case settings

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .chats: "Chats"
        case .contacts: "Contacts"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "bubble.left"
        case .contacts: "person.2"
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
        HStack {
            Group {
                if step > 0 && !isCompleting {
                    Button {
                        focusedField = nil
                        step -= 1
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 15, weight: .medium))
                            Text("Back")
                                .font(.custom("Courier", size: 13))
                        }
                        .foregroundStyle(palette.muted)
                        .frame(minWidth: 82, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                } else {
                    Color.clear.frame(width: 82, height: 44)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                Text(verbatim: "xauxat")
                    .font(.custom("Courier", size: 17).weight(.bold))
                    .tracking(2)
                Text(verbatim: "X -- X")
                    .font(.custom("Courier", size: 15).weight(.bold))
                    .tracking(1.8)
            }
            .foregroundStyle(palette.ink)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("XauXat")

            Spacer(minLength: 0)

            Text("\(step + 1) / 3")
                .font(.custom("Courier", size: 12))
                .foregroundStyle(palette.muted)
                .frame(width: 82, alignment: .trailing)
                .frame(minHeight: 44)
                .accessibilityLabel("Step \(step + 1) of 3")
        }
        .frame(height: 76)
        .padding(.horizontal, 22)
    }

    private func welcomeStep(_ geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text(verbatim: "xauxat")
                    .font(.custom("Courier", size: 33).weight(.bold))
                    .tracking(3.3)
                Text(verbatim: "X -- X")
                    .font(.custom("Courier", size: 22).weight(.bold))
                    .tracking(2.7)
            }
            .foregroundStyle(palette.ink)
            .padding(.top, geometry.size.height < 700 ? 7 : max(28, geometry.size.height * 0.1))
            .accessibilityHidden(true)

            (Text("This is ") + Text("your").italic() + Text(" space."))
                .font(.custom("Courier", size: geometry.size.height < 700 ? 18 : 20))
                .tracking(2.4)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.ink)
                .padding(.top, geometry.size.height < 700 ? 43 : 78)

            Text("No phone number.\nNo email.\nNo global identity.")
                .font(.custom("Courier", size: geometry.size.height < 700 ? 11 : 12))
                .tracking(1.6)
                .lineSpacing(geometry.size.height < 700 ? 8 : 10)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.muted)
                .padding(.top, geometry.size.height < 700 ? 22 : 35)

            Spacer(minLength: 20)

            Text("PRIVATE MESSAGING\nBY DESIGN")
                .font(.custom("Courier", size: 8).weight(.bold))
                .tracking(2.7)
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.muted)
                .padding(.bottom, geometry.size.height < 700 ? 31 : 46)

            primaryButton("CONTINUE PRIVATELY", enabled: true) {
                step = 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    focusedField = .displayName
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
    }

    private func nameStep(_ geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            (Text("What should\npeople call ") + Text("you").italic() + Text("?"))
                .font(.custom("Courier", size: geometry.size.height < 700 ? 22 : 25))
                .tracking(3.2)
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.ink)
                .padding(.top, geometry.size.height < 700 ? 24 : min(120, geometry.size.height * 0.18))

            TextField("Display name", text: $displayName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .displayName)
                .font(.custom("Courier", size: 14))
                .foregroundStyle(palette.ink)
                .tint(palette.ivory)
                .padding(.horizontal, 20)
                .frame(height: 54)
                .overlay {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .stroke(validName || displayName.isEmpty ? palette.muted : palette.danger, lineWidth: 1)
                }
                .padding(.top, geometry.size.height < 700 ? 30 : 51)
                .submitLabel(.continue)
                .onSubmit { if validName { advanceToPIN() } }
                .accessibilityLabel("Display name")

            Text(validName || displayName.isEmpty ? "This doesn’t identify you.\nChange it whenever you want." : "Use a name without unsupported characters.")
                .font(.custom("Courier", size: geometry.size.height < 700 ? 10.5 : 12))
                .tracking(1.1)
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundStyle(validName || displayName.isEmpty ? palette.muted : palette.danger)
                .padding(.top, geometry.size.height < 700 ? 24 : 44)

            Spacer(minLength: 20)

            primaryButton("Continue", enabled: validName, action: advanceToPIN)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 21)
    }

    private func pinStep(_ geometry: GeometryProxy) -> some View {
        let compact = geometry.size.height < 700

        return VStack(spacing: 0) {
            Text("Create your\nPIN")
                .font(.custom("Courier", size: compact ? 22 : 26))
                .tracking(3.2)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.ink)
                .padding(.top, compact ? 12 : min(80, geometry.size.height * 0.1))

            Text("This will protect your XauXat\non this device.")
                .font(.custom("Courier", size: compact ? 10.5 : 12))
                .tracking(1.1)
                .lineSpacing(5)
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
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(palette.ivory)

                Text("Your PIN. Your responsibility.\nIt never leaves your device.\nWe can’t recover it.")
                    .font(.custom("Courier", size: compact ? 10.5 : 12))
                    .tracking(1.1)
                    .lineSpacing(5)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(palette.muted)
                    .padding(.top, compact ? 7 : 13)
            }
            .padding(.top, compact ? 31 : 77)

            Spacer(minLength: 18)

            primaryButton(
                isCompleting ? "Finishing…" : "Finish",
                enabled: validPIN && !isCompleting,
                action: finishOnboarding
            )

            HStack(spacing: 9) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index == step ? palette.ivory : palette.line)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 21)
        .contentShape(Rectangle())
        .onTapGesture { focusedField = .pin }
    }

    private func primaryButton(_ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.custom("Courier", size: label == "CONTINUE PRIVATELY" ? 13 : 16).weight(.bold))
                .tracking(0.6)
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
        guard let token = chatModel.deviceToken else { return }
        Task {
            do {
                let status = try await apiRegisterToken(token: token, notificationMode: .instant)
                await MainActor.run {
                    chatModel.savedToken = token
                    chatModel.tokenStatus = status
                    chatModel.notificationMode = .instant
                }
            } catch {
                logger.error("XauXat onboarding could not apply the default notification mode: \(responseError(error))")
            }
        }
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
                    action: tab == .settings ? nil : { showNewChatSheet = true }
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
        ZStack {
            VStack(spacing: -2) {
                Text(verbatim: "xauxat")
                    .font(.custom("Courier", size: 18).weight(.bold))
                Text(verbatim: "X -- X")
                    .font(.custom("Courier", size: 9).weight(.bold))
                    .tracking(1.1)
            }
            .foregroundStyle(palette.ink)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("XauXat")

            HStack {
                Spacer()
                if let action {
                    Button(action: action) {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(palette.ivoryInk)
                            .frame(width: 38, height: 38)
                            .background(palette.ivory, in: Circle())
                    }
                    .accessibilityLabel("New conversation")
                }
            }
        }
        .frame(height: 60)
        .padding(.horizontal, 22)
        .background(palette.background)
    }
}

private struct XauXatChatsView: View {
    @EnvironmentObject private var chatModel: ChatModel
    let palette: XauXatPalette
    @Binding var parentSheet: SomeSheet<AnyView>?
    @Binding var showNewChatSheet: Bool

    private var chats: [Chat] {
        chatModel.chats.filter {
            !$0.chatInfo.chatDeleted && !$0.chatInfo.contactCard && !xauXatIsChatHidden($0.id)
        }
    }

    var body: some View {
        if chats.isEmpty {
            XauXatEmptyState(
                palette: palette,
                title: "No conversations yet.",
                subtitle: "Your private space starts here.",
                action: { showNewChatSheet = true }
            )
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
                .padding(.top, 8)
            }
            .refreshable {
                try? await reconnectAllServers()
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
                    .font(.custom("Courier", size: 15))
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
        HStack(spacing: 13) {
            ChatInfoImage(chat: chat, size: 48, color: palette.raised)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(chat.chatInfo.chatViewName)
                        .font(.custom("Courier", size: 16).weight(.bold))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if !contactStyle {
                        formatTimestampText(timestamp)
                            .font(.custom("Courier", size: 11))
                            .foregroundStyle(palette.muted)
                    }
                }

                HStack(spacing: 8) {
                    if xauXatIsChatLocked(chat.id) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.muted)
                    }
                    Text(detail)
                        .font(.custom("Courier", size: 13))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                        .privacySensitive(!contactStyle)
                    Spacer(minLength: 8)
                    if contactStyle {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(palette.ivory)
                    } else if chat.chatStats.unreadCount > 0 {
                        Text(verbatim: "\(chat.chatStats.unreadCount)")
                            .font(.custom("Courier", size: 11).weight(.bold))
                            .foregroundStyle(palette.ivoryInk)
                            .frame(minWidth: 21, minHeight: 21)
                            .background(palette.ivory, in: Circle())
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.line)
                .frame(height: 1)
                .padding(.leading, 61)
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
                .font(.custom("Courier", size: 18).weight(.bold))
                .foregroundStyle(palette.ink)
            Text(subtitle)
                .font(.custom("Courier", size: 14))
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
            if let action {
                Button(action: action) {
                    Text("Start a conversation")
                        .font(.custom("Courier", size: 14).weight(.bold))
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
                                    .font(.custom("Courier", size: 18).weight(.bold))
                                    .foregroundStyle(palette.ink)
                                    .lineLimit(1)
                                Text(user.shortDescr?.nonEmpty ?? "Your private identity")
                                    .font(.custom("Courier", size: 13))
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
        if plusEntitlements.hasLocalDebugAccess { return "Included" }
        switch plusEntitlements.status {
        case .active: return "Active"
        case .checking: return "Checking"
        case .notPurchased, .expired, .revoked, .unverified, .unavailable: return "Free"
        }
    }
}

private struct XauXatHelpDestination: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ChatHelp(dismissSettingsSheet: dismiss)
    }
}

private struct XauXatPrivacyView: View {
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
                }

                Text("XauXat always hides its content in the App Switcher. Your security settings stay on this device.")
                    .font(.custom("Courier", size: 11))
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
                        .font(.custom("Courier", size: 14))
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
                                        .font(.custom("Courier", size: 14).weight(.bold))
                                        .foregroundStyle(palette.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 12)
                                    Text("Show")
                                        .font(.custom("Courier", size: 12).weight(.bold))
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
                        .font(.custom("Courier", size: 11))
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
    @State private var changing = false
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
                        .disabled(changing)
                    }
                }

                Text("Notification content remains end-to-end encrypted. You can control lock-screen previews in iOS Settings.")
                    .font(.custom("Courier", size: 11))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 5)
                    .padding(.top, 18)
            }
            .padding(22)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .buttonStyle(.plain)
        .overlay {
            if changing {
                ProgressView()
                    .tint(palette.ivory)
            }
        }
        .onAppear {
            (chatModel.savedToken, chatModel.tokenStatus, chatModel.notificationMode, chatModel.notificationServer) = apiGetNtfToken()
            mode = chatModel.notificationMode
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
        guard newMode != mode, let token = chatModel.deviceToken else {
            if chatModel.deviceToken == nil { errorMessage = "No notification token is available on this device yet." }
            return
        }
        changing = true
        Task {
            do {
                if newMode == .off {
                    try await apiDeleteToken(token: token)
                    await MainActor.run {
                        chatModel.tokenStatus = .new
                        chatModel.notificationServer = nil
                    }
                } else {
                    _ = try await apiRegisterToken(token: token, notificationMode: newMode)
                }
                let (_, tokenStatus, actualMode, server) = apiGetNtfToken()
                await MainActor.run {
                    chatModel.tokenStatus = tokenStatus
                    chatModel.notificationMode = actualMode
                    chatModel.notificationServer = server
                    mode = actualMode
                    changing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = responseError(error)
                    mode = chatModel.notificationMode
                    changing = false
                }
            }
        }
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
                                    .font(.custom("Courier", size: 10))
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
                    .font(.custom("Courier", size: 11))
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
                        .font(.custom("Courier", size: 16).weight(.bold))
                        .tracking(2)
                }
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 42)

                XauXatSettingsCard(palette: palette) {
                    XauXatValueRow(palette: palette, title: "App version", value: appVersion.map { "v\($0)" } ?? "Unknown")
                    XauXatValueRow(palette: palette, title: "Build", value: appBuild ?? "Unknown")
                    if let coreVersion {
                        XauXatValueRow(palette: palette, title: "SimpleX core", value: "v\(coreVersion.version)")
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
            .font(.custom("Courier", size: 11).weight(.bold))
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
                .font(.custom("Courier", size: 14))
                .foregroundStyle(palette.ink)
            Spacer()
            if let value {
                Text(value)
                    .font(.custom("Courier", size: 11))
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
                        .font(.custom("Courier", size: 14))
                        .foregroundStyle(palette.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(.custom("Courier", size: 10))
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
                    .font(.custom("Courier", size: 14))
                    .foregroundStyle(palette.ink)
                Text(subtitle)
                    .font(.custom("Courier", size: 10))
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
                .font(.custom("Courier", size: 14))
                .foregroundStyle(palette.ink)
            Spacer(minLength: 12)
            Text(value)
                .font(.custom("Courier", size: 12).weight(.bold))
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
                Button { selection = tab } label: {
                    let selected = selection == tab
                    VStack(spacing: 6) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 23, weight: selected ? .medium : .light))
                        Text(tab.title)
                            .font(.custom("Courier", size: 10).weight(selected ? .bold : .regular))
                    }
                    .foregroundStyle(selected ? palette.ivory : palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 64)
                }
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(.top, 4)
        .background(palette.background)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.line).frame(height: 1)
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
                    .font(.custom("Courier", size: 15))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                XauXatSettingsCard(palette: palette) {
                    statusRow("Embedded Tor", value: torState)
                    statusRow("SimpleX route", value: routeState)
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
                            .font(.custom("Courier", size: 14).weight(.bold))
                    }
                    .foregroundStyle(palette.ivoryInk)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(palette.ivory)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .disabled(verification == .checking || !isXauXatManagedTorConfig(getNetCfg()))

                if case let .failed(message) = verification {
                    Text(message)
                        .font(.custom("Courier", size: 12))
                        .foregroundStyle(palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("This check sends no chat data. It opens a fresh SOCKS5 tunnel through the same local Tor endpoint and confirms that Tor Project is reachable through it. It does not request, display or store an exit IP.")
                    .font(.custom("Courier", size: 12))
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
                .font(.custom("Courier", size: 14))
                .foregroundStyle(palette.ink)
            Spacer()
            Text(value)
                .font(.custom("Courier", size: 12).weight(.bold))
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
