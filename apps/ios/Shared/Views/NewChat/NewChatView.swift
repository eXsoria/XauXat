//
//  NewChatView.swift
//  SimpleX (iOS)
//
//  Created by spaced4ndy on 28.11.2023.
//  Copyright © 2023 SimpleX Chat. All rights reserved.
//
// Spec: spec/client/navigation.md

import SwiftUI
import SimpleXChat
import CodeScanner
import AVFoundation
import SimpleXChat

struct SomeAlert: Identifiable {
    var alert: Alert
    var id: String
}

struct SomeActionSheet: Identifiable {
    var actionSheet: ActionSheet
    var id: String
}

struct SomeSheet<Content: View>: Identifiable {
    @ViewBuilder var content: Content
    var id: String
    var fraction = 0.4
}

private enum NewChatViewAlert: Identifiable {
    case newChatSomeAlert(alert: SomeAlert)
    var id: String {
        switch self {
        case let .newChatSomeAlert(alert): return "newChatSomeAlert \(alert.id)"
        }
    }
}

enum NewChatOption: Identifiable {
    case invite
    case connect

    var id: Self { self }
}

func showKeepInvitationAlert() {
    if let showingInvitation = ChatModel.shared.showingInvitation,
       !showingInvitation.connChatUsed {
        showAlert(
            NSLocalizedString("Keep unused invitation?", comment: "alert title"),
            message: NSLocalizedString("You can view invitation link again in connection details.", comment: "alert message"),
            actions: {[
                UIAlertAction(
                    title: NSLocalizedString("Keep", comment: "alert action"),
                    style: .default
                ),
                UIAlertAction(
                    title: NSLocalizedString("Delete", comment: "alert action"),
                    style: .destructive,
                    handler: { _ in
                        Task {
                            try? await revokeXauXatContactInvite(showingInvitation.pcc)
                        }
                    }
                )
            ]}
        )
    }
    ChatModel.shared.showingInvitation = nil
}

// Spec: spec/client/navigation.md#NewChatView
struct NewChatView: View {
    @EnvironmentObject var m: ChatModel
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject private var plusEntitlements: XauXatPlusEntitlements
    @State var selection: NewChatOption
    @State var showQRCodeScanner = false
    var onboarding: Bool = false
    @State private var invitationUsed: Bool = false
    @State private var connLinkInvitation: CreatedConnLink = CreatedConnLink(connFullLink: "", connShortLink: nil)
    @State private var showShortLink = true
    @State private var creatingConnReq = false
    @State var choosingProfile = false
    @State private var pastedLink: String = ""
    @State private var alert: NewChatViewAlert?
    @State private var contactConnection: PendingContactConnection? = nil
    @State private var contactConnections: [PendingContactConnection] = []
    @State private var connLinkInvitations: [CreatedConnLink] = []
    @State private var inviteLifetime: XauXatContactInviteLifetime = .never
    @State private var customInviteExpiry = Date.now.addingTimeInterval(24 * 60 * 60)
    @State private var allowInviteMessages = true
    @State private var allowInviteCalls = true
    @State private var inviteMaximumUses = 1
    @State private var invitePolicy: XauXatContactInvitePolicy? = nil

    var body: some View {
        VStack(alignment: .leading) {
            if !onboarding {
                Picker("New chat", selection: $selection) {
                    Label(
                        "1-time link",
                        systemImage: plusEntitlements.isAuthorized(for: .advancedContactInvites) ? "link" : "lock.fill"
                    )
                        .tag(NewChatOption.invite)
                    Label("Connect via link", systemImage: "qrcode")
                        .tag(NewChatOption.connect)
                }
                .pickerStyle(.segmented)
                .padding()
                .onChange(of: $selection.wrappedValue) { opt in
                    if opt == NewChatOption.connect {
                        showQRCodeScanner = true
                    }
                }
            }

            VStack {
                // it seems there's a bug in iOS 15 if several views in switch (or if-else) statement have different transitions
                // https://developer.apple.com/forums/thread/714977?answerId=731615022#731615022
                if case .invite = selection {
                    Group {
                        if plusEntitlements.isAuthorized(for: .advancedContactInvites) {
                            prepareAndInviteView()
                        } else {
                            lockedOneTimeInviteView()
                        }
                    }
                        .transition(.move(edge: .leading))
                        .onAppear {
                            refreshInvitePolicy()
                        }
                }
                if case .connect = selection {
                    ConnectView(showQRCodeScanner: $showQRCodeScanner, pastedLink: $pastedLink, alert: $alert, onboarding: onboarding)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ThemedBackground(grouped: true))
            .background(
                // Rectangle is needed for swipe gesture to work on mostly empty views (creatingLinkProgressView and retryButton)
                Rectangle()
                    .fill(theme.base == DefaultTheme.LIGHT ? theme.colors.background.asGroupedBackground(theme.base.mode) : theme.colors.background)
            )
            .animation(.easeInOut(duration: 0.3333), value: selection)
            .gesture(DragGesture(minimumDistance: 20.0, coordinateSpace: .local)
                .onChanged { value in
                    switch(value.translation.width, value.translation.height) {
                    case (...0, -30...30): // left swipe
                        if selection == .invite {
                            selection = .connect
                        }
                    case (0..., -30...30): // right swipe
                        if selection == .connect {
                            selection = .invite
                        }
                    default: ()
                    }
                },
                including: onboarding ? .subviews : .all
            )
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !onboarding {
                    InfoSheetButton {
                        AddContactLearnMore(showTitle: true)
                    }
                } else {
                    Image(systemName: "info.circle").opacity(0)
                }
            }
        }
        .if(onboarding) { $0.navigationBarTitleDisplayMode(.inline) }
        .modifier(ThemedBackground(grouped: true))
        .onChange(of: invitationUsed) { used in
            if used && !(m.showingInvitation?.connChatUsed ?? true) {
                m.markShowingInvitationUsed()
            }
        }
        .onDisappear {
            if !choosingProfile {
                showKeepInvitationAlert()
                contactConnection = nil
                contactConnections = []
                connLinkInvitations = []
            }
        }
        .task(id: invitePolicy?.expiresAt) {
            await waitForInviteExpiry()
        }
        .alert(item: $alert) { a in
            switch(a) {
            case let .newChatSomeAlert(a):
                return a.alert
            }
        }
    }

    private func prepareAndInviteView() -> some View {
        ZStack { // ZStack is needed for views to not make transitions between each other
            if connLinkInvitation.connFullLink != "" {
                InviteView(
                    invitationUsed: $invitationUsed,
                    contactConnection: $contactConnection,
                    contactConnections: $contactConnections,
                    connLinkInvitation: $connLinkInvitation,
                    connLinkInvitations: $connLinkInvitations,
                    showShortLink: $showShortLink,
                    choosingProfile: $choosingProfile,
                    invitePolicy: $invitePolicy,
                    onboarding: onboarding
                )
            } else if creatingConnReq {
                creatingLinkProgressView()
            } else {
                inviteSetupView()
            }
        }
    }

    private func inviteSetupView() -> some View {
        Form {
            Section {
                Picker("Expires", selection: $inviteLifetime) {
                    ForEach(XauXatContactInviteLifetime.allCases) { lifetime in
                        Text(lifetime.label).tag(lifetime)
                    }
                }
                if inviteLifetime == .custom {
                    DatePicker(
                        "Expiry date",
                        selection: $customInviteExpiry,
                        in: Date.now...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            } header: {
                Text("Invite lifetime")
            } footer: {
                if inviteLifetime == .never {
                    Text("The invite remains valid until it is used or revoked.")
                } else if inviteLifetime == .custom {
                    Text("XauXat will permanently revoke the invite on the selected date.")
                } else {
                    Text("XauXat will permanently revoke the invite when this duration ends.")
                }
            }

            Section {
                Toggle("Messages", isOn: $allowInviteMessages)
                Toggle("Audio calls", isOn: $allowInviteCalls)
            } header: {
                Text("Contact permissions")
            } footer: {
                Text("These authenticated restrictions are shown before the contact accepts the invite.")
            }

            Section {
                Stepper("Maximum uses: \(inviteMaximumUses)", value: $inviteMaximumUses, in: 1...5)
            } header: {
                Text("Usage limit")
            } footer: {
                Text(inviteMaximumUses == 1
                     ? "The invite can create one contact."
                     : "XauXat combines independent SimpleX one-time links so concurrent use cannot exceed this limit.")
            }

            Section {
                Button(inviteLifetime == .never ? "Create invite" : "Create expiring invite") {
                    authorizeAndCreateInvitation()
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func lockedOneTimeInviteView() -> some View {
        VStack(spacing: 18) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(theme.colors.secondary)
                .accessibilityHidden(true)
            Text("One-time contact invites")
                .font(.title2.weight(.semibold))
            Text("Create a link that becomes invalid as soon as the first contact uses it.")
                .foregroundStyle(theme.colors.secondary)
                .multilineTextAlignment(.center)
            NavigationLink {
                XauXatPlusView()
                    .navigationTitle("XauXat Plus")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label("Open XauXat Plus", systemImage: "lock.open")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func authorizeAndCreateInvitation() {
        if inviteLifetime == .never && allowInviteMessages && allowInviteCalls && inviteMaximumUses == 1 {
            createInvitation()
            return
        }
        authenticate(reason: NSLocalizedString("Create an advanced contact invite", comment: "authentication reason")) { result in
            switch result {
            case .success:
                createInvitation()
            case .failed:
                AlertManager.shared.showAlert(laFailedAlert())
            case .unavailable:
                AlertManager.shared.showAlert(laUnavailableInstructionAlert())
            }
        }
    }

    private func createInvitation() {
        guard plusEntitlements.isAuthorized(for: .advancedContactInvites) else { return }
        if connLinkInvitation.connFullLink == "" && contactConnections.isEmpty && !creatingConnReq {
            creatingConnReq = true
            let maximumUses = inviteMaximumUses
            let lifetime = inviteLifetime
            let customExpiry = customInviteExpiry
            let messagesAllowed = allowInviteMessages
            let callsAllowed = allowInviteCalls
            Task {
                _ = try? await Task.sleep(nanoseconds: 250_000000)
                var created: [(CreatedConnLink, PendingContactConnection)] = []
                for _ in 0..<maximumUses {
                    guard let invitation = await apiAddContact(incognito: incognitoGroupDefault.get()) else { break }
                    created.append(invitation)
                }
                if created.count == maximumUses, let first = created.first {
                    let expiresAt = lifetime.expiresAt(custom: customExpiry)
                    let permissions = XauXatContactInvitePermissions(messages: messagesAllowed, calls: callsAllowed)
                    let bundleId = maximumUses > 1 ? UUID().uuidString : nil
                    let needsPolicy = expiresAt != nil || permissions.isRestricted || maximumUses > 1
                    let policies = created.map { _, pcc in
                        needsPolicy ? XauXatContactInvitePolicy(
                            connectionId: pcc.pccConnId,
                            createdAt: .now,
                            expiresAt: expiresAt,
                            permissions: permissions,
                            bundleId: bundleId,
                            maxUses: maximumUses
                        ) : nil
                    }
                    policies.compactMap { $0 }.forEach { _ = xauXatSaveContactInvitePolicy($0) }
                    await MainActor.run {
                        let links = created.map(\.0)
                        let connections = created.map(\.1)
                        invitePolicy = policies.first ?? nil
                        connections.forEach { m.updateContactConnection($0) }
                        m.showingInvitation = ShowingInvitation(pcc: first.1, connChatUsed: false)
                        connLinkInvitation = first.0
                        connLinkInvitations = links
                        contactConnection = first.1
                        contactConnections = connections
                    }
                } else {
                    for (_, pcc) in created {
                        try? await apiDeleteChat(type: .contactConnection, id: pcc.apiId)
                        await MainActor.run { m.removeChat(pcc.id) }
                    }
                    await MainActor.run {
                        creatingConnReq = false
                    }
                }
            }
        }
    }

    // Rectangle here and in retryButton are needed for gesture to work
    private func creatingLinkProgressView() -> some View {
        ProgressView("Creating link…")
            .progressViewStyle(.circular)
    }

    private func retryButton() -> some View {
        Button(action: createInvitation) {
            VStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                Text("Retry")
            }
        }
    }

    private func refreshInvitePolicy() {
        guard let connectionId = contactConnection?.pccConnId else { return }
        invitePolicy = xauXatObserveContactInvitePolicy(connectionId: connectionId)
    }

    private func waitForInviteExpiry() async {
        guard let policy = invitePolicy, policy.state == .active, let expiresAt = policy.expiresAt else { return }
        let delay = expiresAt.timeIntervalSinceNow
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        guard !Task.isCancelled,
              let expired = xauXatObserveContactInvitePolicy(connectionId: policy.connectionId),
              expired.state == .expired else { return }
        let expiringConnections = contactConnections.filter { pcc in
            guard let stored = xauXatObserveContactInvitePolicy(connectionId: pcc.pccConnId) else { return false }
            return stored.bundleId == policy.bundleId || stored.connectionId == policy.connectionId
        }
        if !expiringConnections.isEmpty {
            for pcc in expiringConnections {
                try? await apiDeleteChat(type: .contactConnection, id: pcc.apiId)
            }
            await MainActor.run {
                invitePolicy = expired
                expiringConnections.forEach { m.removeChat($0.id) }
                m.showingInvitation = nil
            }
        }
    }
}

private enum XauXatContactInviteLifetime: Int, CaseIterable, Identifiable {
    case never
    case fifteenMinutes
    case oneHour
    case oneDay
    case sevenDays
    case custom

    var id: Self { self }

    var label: LocalizedStringKey {
        switch self {
        case .never: "Never"
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .oneDay: "24 hours"
        case .sevenDays: "7 days"
        case .custom: "Custom date"
        }
    }

    func expiresAt(custom: Date) -> Date? {
        switch self {
        case .never: nil
        case .fifteenMinutes: Date.now.addingTimeInterval(15 * 60)
        case .oneHour: Date.now.addingTimeInterval(60 * 60)
        case .oneDay: Date.now.addingTimeInterval(24 * 60 * 60)
        case .sevenDays: Date.now.addingTimeInterval(7 * 24 * 60 * 60)
        case .custom: custom
        }
    }
}

private func incognitoProfileImage() -> some View {
    Image(systemName: "theatermasks.fill")
        .resizable()
        .scaledToFit()
        .frame(width: 30)
        .foregroundColor(.indigo)
}

private struct InviteView: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var chatModel: ChatModel
    @EnvironmentObject var theme: AppTheme
    @Binding var invitationUsed: Bool
    @Binding var contactConnection: PendingContactConnection?
    @Binding var contactConnections: [PendingContactConnection]
    @Binding var connLinkInvitation: CreatedConnLink
    @Binding var connLinkInvitations: [CreatedConnLink]
    @Binding var showShortLink: Bool
    @Binding var choosingProfile: Bool
    @Binding var invitePolicy: XauXatContactInvitePolicy?
    var onboarding: Bool = false
    @State private var authenticatedShareLink: String?

    @AppStorage(GROUP_DEFAULT_INCOGNITO, store: groupDefaults) private var incognitoDefault = false

    var body: some View {
        List {
            Section(header: sectionHeader) {
                shareLinkView()
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 10))

            if let policy = observedPolicy {
                Section {
                    infoRow("Invite status", inviteStatus)
                    if let expiresAt = policy.expiresAt {
                        infoRow("Expires", expiresAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let maximumUses = policy.maxUses {
                        infoRow("Used", "\(consumedUses) of \(maximumUses)")
                        infoRow("Remaining", "\(max(0, maximumUses - consumedUses))")
                    }
                    infoRow("Messages", policy.permissions?.messages == false ? "Blocked" : "Allowed")
                    infoRow("Audio calls", policy.permissions?.calls == false ? "Blocked" : "Allowed")
                }
            }

            if inviteAvailable {
                qrCodeView()
            }
            if !onboarding, contactConnections.count <= 1, let selectedProfile = chatModel.currentUser {
                Section {
                    NavigationLink {
                        ActiveProfilePicker(
                            contactConnection: $contactConnection,
                            connLinkInvitation: $connLinkInvitation,
                            incognitoEnabled: $incognitoDefault,
                            choosingProfile: $choosingProfile,
                            selectedProfile: selectedProfile
                        )
                    } label: {
                        HStack {
                            if incognitoDefault {
                                incognitoProfileImage()
                                Text("Incognito")
                            } else {
                                ProfileImage(imageStr: chatModel.currentUser?.image, size: 30)
                                Text(chatModel.currentUser?.chatViewName ?? "")
                            }
                        }
                    }
                } header: {
                    Text("Share profile").foregroundColor(theme.colors.secondary)
                } footer: {
                    if incognitoDefault {
                        Text("A new random profile will be shared.")
                    }
                }
            }
        }
        .onChange(of: incognitoDefault) { incognito in
            setInvitationUsed()
        }
        .onChange(of: chatModel.currentUser) { u in
            setInvitationUsed()
        }
        .onAppear(perform: refreshAuthenticatedShareLink)
        .onChange(of: showShortLink) { _ in refreshAuthenticatedShareLink() }
        .onChange(of: invitePolicy) { _ in refreshAuthenticatedShareLink() }
        .onReceive(chatModel.$chats) { _ in refreshAuthenticatedShareLink() }
    }

    private var observedPolicy: XauXatContactInvitePolicy? {
        guard let connectionId = contactConnection?.pccConnId else { return invitePolicy }
        return xauXatObserveContactInvitePolicy(connectionId: connectionId) ?? invitePolicy
    }

    private var bundlePolicies: [XauXatContactInvitePolicy] {
        guard let policy = observedPolicy else { return [] }
        guard let bundleId = policy.bundleId else { return [policy] }
        return xauXatContactInviteBundlePolicies(bundleId: bundleId)
    }

    private var consumedUses: Int {
        bundlePolicies.filter { $0.state == .used }.count
    }

    private var inviteAvailable: Bool {
        observedPolicy == nil || bundlePolicies.contains(where: { $0.state == .active })
    }

    private var inviteStatus: String {
        guard let policy = observedPolicy else { return "Unused" }
        if bundlePolicies.allSatisfy({ $0.state == .used }) { return "Fully used" }
        if bundlePolicies.contains(where: { $0.state == .active }) { return "Active" }
        if bundlePolicies.contains(where: { $0.state == .expired }) { return "Expired" }
        if bundlePolicies.contains(where: { $0.state == .revoked }) { return "Revoked" }
        return policy.state == .used ? "Used" : "Unused"
    }

    private var sectionHeader: some View {
        #if SIMPLEX_ASSETS
        VStack(alignment: .leading, spacing: 0) {
            Image(colorScheme == .light
                ? (onboarding ? "one-time-link" : "one-time-link-small")
                : (onboarding ? "one-time-link-light" : "one-time-link-small-light"))
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
            sectionHeaderText
        }
        .padding(.bottom, 6)
        #else
        sectionHeaderText
            .if(onboarding) { $0.padding(.bottom, 6) }
        #endif
    }

    @ViewBuilder private var sectionHeaderText: some View {
        if onboarding {
            Text("Send the link via any messenger - it's secure. Ask to paste into SimpleX.")
                .font(.body).foregroundColor(theme.colors.onBackground).textCase(nil)
        } else {
            Text((observedPolicy?.maxUses ?? 1) > 1 ? "Share this limited-use invite link" : "Share this 1-time invite link")
                .foregroundColor(theme.colors.secondary)
        }
    }

    private func shareLinkView() -> some View {
        HStack(spacing: 8) {
            linkTextView(authenticatedShareLink ?? NSLocalizedString("Authenticated link unavailable", comment: "invite link error"))
            Button {
                guard let authenticatedShareLink else { return }
                showShareSheet(items: [authenticatedShareLink])
                setInvitationUsed()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .padding(.top, -7)
                    .padding(.horizontal, 8)
            }
            .disabled(!inviteAvailable || authenticatedShareLink == nil)
        }
        .frame(maxWidth: .infinity)
    }

    private func qrCodeView() -> some View {
        Section {
            if let authenticatedShareLink {
                QRCode(uri: authenticatedShareLink, onShare: setInvitationUsed)
                    .id("simplex-qrcode-view-for-\(authenticatedShareLink)")
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
                .padding(.horizontal)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
        } header: {
            if onboarding {
                Text("Or show QR in person or via video call.").font(.body).foregroundColor(theme.colors.onBackground).textCase(nil)
            } else {
                ToggleShortLinkHeader(text: Text("Or show this code"), link: connLinkInvitation, short: $showShortLink)
            }
        }
    }

    private func refreshAuthenticatedShareLink() {
        let activeLinks = zip(contactConnections, connLinkInvitations).compactMap { connection, link in
            let state = xauXatObserveContactInvitePolicy(connectionId: connection.pccConnId)?.state
            return state == nil || state == .active ? link : nil
        }
        authenticatedShareLink = xauXatContactInviteShareLink(
            activeLinks.isEmpty ? (connLinkInvitations.isEmpty ? [connLinkInvitation] : connLinkInvitations) : activeLinks,
            short: showShortLink,
            policy: observedPolicy
        )
    }

    private func setInvitationUsed() {
        if !invitationUsed {
            invitationUsed = true
        }
    }
}

func xauXatContactInviteShareLink(
    _ connectionLink: CreatedConnLink,
    short: Bool,
    policy: XauXatContactInvitePolicy?
) -> String? {
    let link = connectionLink.simplexChatUri(short: short)
    guard let policy else { return link }
    return xauXatSignedContactInviteLink(
        link: link,
        expiresAt: policy.expiresAt,
        permissions: policy.permissions ?? .init()
    )
}

func xauXatContactInviteShareLink(
    _ connectionLinks: [CreatedConnLink],
    short: Bool,
    policy: XauXatContactInvitePolicy?
) -> String? {
    let links = connectionLinks.map { $0.simplexChatUri(short: short) }
    guard let policy else { return links.first }
    return xauXatSignedContactInviteLink(
        links: links,
        expiresAt: policy.expiresAt,
        permissions: policy.permissions ?? .init()
    )
}

private enum ProfileSwitchStatus {
    case switchingUser
    case switchingIncognito
    case idle
}

private struct ActiveProfilePicker: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var chatModel: ChatModel
    @EnvironmentObject var theme: AppTheme
    @Binding var contactConnection: PendingContactConnection?
    @Binding var connLinkInvitation: CreatedConnLink
    @Binding var incognitoEnabled: Bool
    @Binding var choosingProfile: Bool
    @State private var alert: SomeAlert?
    @State private var profileSwitchStatus: ProfileSwitchStatus = .idle
    @State private var switchingProfileByTimeout = false
    @State private var lastSwitchingProfileByTimeoutCall: Double?
    @State private var profiles: [User] = []
    @State private var searchTextOrPassword = ""
    @State private var showIncognitoSheet = false
    @State private var incognitoFirst: Bool = false
    @State var selectedProfile: User
    var trimmedSearchTextOrPassword: String { searchTextOrPassword.trimmingCharacters(in: .whitespaces)}

    var body: some View {
        viewBody()
            .navigationTitle("Select chat profile")
            .searchable(text: $searchTextOrPassword, placement: .navigationBarDrawer(displayMode: .always))
            .autocorrectionDisabled(true)
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                profiles = chatModel.users
                    .map { $0.user }
            }
            .onChange(of: incognitoEnabled) { incognito in
                if profileSwitchStatus != .switchingIncognito {
                    return
                }

                Task {
                    do {
                        if let contactConn = contactConnection,
                           let conn = try await apiSetConnectionIncognito(connId: contactConn.pccConnId, incognito: incognito) {
                            await MainActor.run {
                                contactConnection = conn
                                chatModel.updateContactConnection(conn)
                                profileSwitchStatus = .idle
                                dismiss()
                            }
                        }
                    } catch {
                        profileSwitchStatus = .idle
                        incognitoEnabled = !incognito
                        logger.error("apiSetConnectionIncognito error: \(responseError(error))")
                        await MainActor.run {
                            showErrorAlert(error, NSLocalizedString("Error changing to incognito!", comment: ""))
                        }
                    }
                }
            }
            .onChange(of: profileSwitchStatus) { sp in
                if sp != .idle {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        switchingProfileByTimeout = profileSwitchStatus != .idle
                    }
                } else {
                    switchingProfileByTimeout = false
                }
            }
            .onChange(of: selectedProfile) { profile in
                if (profileSwitchStatus != .switchingUser) {
                    return
                }
                Task {
                    do {
                        if let contactConn = contactConnection,
                           let conn = try await apiChangeConnectionUser(connId: contactConn.pccConnId, userId: profile.userId) {
                            await MainActor.run {
                                contactConnection = conn
                                connLinkInvitation = conn.connLinkInv ?? CreatedConnLink(connFullLink: "", connShortLink: nil)
                                incognitoEnabled = false
                                chatModel.updateContactConnection(conn)
                            }
                            do {
                                try await changeActiveUserAsync_(profile.userId, viewPwd: profile.hidden ? trimmedSearchTextOrPassword : nil)
                                await MainActor.run {
                                    profileSwitchStatus = .idle
                                    dismiss()
                                }
                            } catch {
                                await MainActor.run {
                                    profileSwitchStatus = .idle
                                    alert = SomeAlert(
                                        alert: Alert(
                                            title: Text("Error switching profile"),
                                            message: Text("Your connection was moved to \(profile.chatViewName) but an error happened when switching profile.")
                                        ),
                                        id: "switchingProfileError"
                                    )
                                }
                            }
                        }
                    } catch {
                        await MainActor.run {
                            profileSwitchStatus = .idle
                            if let currentUser = chatModel.currentUser {
                                selectedProfile = currentUser
                            }
                            showErrorAlert(error, NSLocalizedString("Error changing connection profile", comment: ""))
                        }
                    }
                }
            }
            .alert(item: $alert) { a in
                a.alert
            }
            .onAppear {
                incognitoFirst = incognitoEnabled
                choosingProfile = true
            }
            .onDisappear {
                choosingProfile = false
            }
            .sheet(isPresented: $showIncognitoSheet) {
                IncognitoHelp()
            }
    }


    @ViewBuilder private func viewBody() -> some View {
        profilePicker()
            .allowsHitTesting(!switchingProfileByTimeout)
            .modifier(ThemedBackground(grouped: true))
            .overlay {
                if switchingProfileByTimeout {
                    ProgressView()
                        .scaleEffect(2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
    }

    private func filteredProfiles() -> [User] {
        let s = trimmedSearchTextOrPassword
        let lower = s.localizedLowercase

        return profiles.filter { u in
            if (u.activeUser || !u.hidden) && (s == "" || u.chatViewName.localizedLowercase.contains(lower)) {
                return true
            }
            return correctPassword(u, s)
        }
    }

    private func profilerPickerUserOption(_ user: User) -> some View {
        Button {
            if selectedProfile == user && incognitoEnabled {
                incognitoEnabled = false
                profileSwitchStatus = .switchingIncognito
            } else if selectedProfile != user {
                selectedProfile = user
                profileSwitchStatus = .switchingUser
            }
        } label: {
            HStack {
                ProfileImage(imageStr: user.image, size: 30)
                    .padding(.trailing, 2)
                NameWithBadge(
                    Text(user.chatViewName).foregroundColor(theme.colors.onBackground),
                    user.profile.localBadge
                )
                .lineLimit(1)
                Spacer()
                if selectedProfile == user, !incognitoEnabled {
                    Image(systemName: "checkmark")
                        .resizable().scaledToFit().frame(width: 16)
                        .foregroundColor(theme.colors.primary)
                }
            }
        }
    }

    @ViewBuilder private func profilePicker() -> some View {
        let incognitoOption = Button {
            if !incognitoEnabled {
                incognitoEnabled = true
                profileSwitchStatus = .switchingIncognito
            }
        } label : {
            HStack {
                incognitoProfileImage()
                Text("Incognito")
                    .foregroundColor(theme.colors.onBackground)
                Image(systemName: "info.circle")
                    .foregroundColor(theme.colors.primary)
                    .font(.system(size: 14))
                    .onTapGesture {
                        showIncognitoSheet = true
                    }
                Spacer()
                if incognitoEnabled {
                    Image(systemName: "checkmark")
                        .resizable().scaledToFit().frame(width: 16)
                        .foregroundColor(theme.colors.primary)
                }
            }
        }

        List {
            let filteredProfiles = filteredProfiles()
            let activeProfile = filteredProfiles.first { u in u.activeUser }

            if let selectedProfile = activeProfile {
                let otherProfiles = filteredProfiles
                    .filter { u in u.userId != activeProfile?.userId }
                    .sorted(using: KeyPathComparator<User>(\.activeOrder, order: .reverse))

                if incognitoFirst {
                    incognitoOption
                    profilerPickerUserOption(selectedProfile)
                } else {
                    profilerPickerUserOption(selectedProfile)
                    incognitoOption
                }

                ForEach(otherProfiles) { p in
                    profilerPickerUserOption(p)
                }
            } else {
                incognitoOption
                ForEach(filteredProfiles) { p in
                    profilerPickerUserOption(p)
                }
            }
        }
        .opacity(switchingProfileByTimeout ? 0.4 : 1)
    }
}

private struct ConnectView: View {
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var connectProgressManager = ConnectProgressManager.shared
    @Environment(\.dismiss) var dismiss: DismissAction
    @EnvironmentObject var theme: AppTheme
    @Binding var showQRCodeScanner: Bool
    @Binding var pastedLink: String
    @Binding var alert: NewChatViewAlert?
    var onboarding: Bool = false
    @State var scannerPaused: Bool = false
    @State private var pasteboardHasStrings = UIPasteboard.general.hasStrings

    var body: some View {
        List {
            Section(header: connectSectionHeader) {
                pasteLinkView()
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))

            Section(header: Text("Or scan QR code").foregroundColor(theme.colors.secondary)) {
                ScannerInView(showQRCodeScanner: $showQRCodeScanner, scannerPaused: $scannerPaused, processQRCode: processQRCode)
            }
        }
        .onDisappear {
            connectProgressManager.cancelConnectProgress()
        }
    }

    @ViewBuilder private func pasteLinkView() -> some View {
        if pastedLink == "" {
            ZStack(alignment: .trailing) {
                Button {
                    if let str = UIPasteboard.general.string {
                        let candidate = str.trimmingCharacters(in: .whitespaces)
                        if xauXatIsProtectedGroupInviteLink(candidate) {
                            pastedLink = candidate
                            connect(candidate)
                            return
                        }
                        switch strConnectTarget(candidate) {
                        case let .link(text, _, _):
                            pastedLink = text
                            connect(candidate)
                        case let .name(text, _):
                            pastedLink = text
                            connect(pastedLink)
                        case .none:
                            alert = .newChatSomeAlert(alert: SomeAlert(
                                alert: mkAlert(title: "Invalid link", message: "The text you pasted is not a SimpleX link."),
                                id: "pasteLinkView: code is not a SimpleX link"
                            ))
                        }
                    }
                } label: {
                    Text("Tap to paste link").foregroundColor(theme.colors.primary)
                }
                .disabled(!pasteboardHasStrings)
                .frame(maxWidth: .infinity, alignment: .center)
                if connectProgressManager.showConnectProgress != nil {
                    ProgressView()
                }
            }
        } else {
            HStack {
                linkTextView(pastedLink)
                if connectProgressManager.showConnectProgress != nil {
                    ProgressView()
                }
            }
        }
    }

    private func processQRCode(_ resp: Result<ScanResult, ScanError>) {
        switch resp {
        case let .success(r):
            let link = r.string
            if strIsSimplexLink(r.string) || xauXatIsProtectedGroupInviteLink(r.string) {
                connect(link)
            } else {
                alert = .newChatSomeAlert(alert: SomeAlert(
                    alert: mkAlert(title: "Invalid QR code", message: "The code you scanned is not a SimpleX link QR code."),
                    id: "processQRCode: code is not a SimpleX link"
                ))
            }
        case let .failure(e):
            logger.error("processQRCode QR code error: \(e.localizedDescription)")
            alert = .newChatSomeAlert(alert: SomeAlert(
                alert: mkAlert(title: "Invalid QR code", message: "Error scanning code: \(e.localizedDescription)"),
                id: "processQRCode: failure"
            ))
        }
    }

    private var connectSectionHeader: some View {
        #if SIMPLEX_ASSETS
        VStack(alignment: .leading, spacing: 0) {
            Image(colorScheme == .light
                ? (onboarding ? "connect-via-link" : "connect-via-link-small")
                : (onboarding ? "connect-via-link-light" : "connect-via-link-small-light"))
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
            Text("Paste the link you received").foregroundColor(theme.colors.secondary)
        }
        .padding(.bottom, 4)
        #else
        Text("Paste the link you received").foregroundColor(theme.colors.secondary)
        #endif
    }

    private func connect(_ link: String) {
        scannerPaused = true
        planAndConnect(
            link,
            theme: theme,
            dismiss: true,
            cleanup: {
                pastedLink = ""
                scannerPaused = false
            }
        )
    }
}

struct ScannerInView: View {
    @Binding var showQRCodeScanner: Bool
    var scannerPaused: Binding<Bool>? = nil
    let processQRCode: (_ resp: Result<ScanResult, ScanError>) -> Void
    @State private var cameraAuthorizationStatus: AVAuthorizationStatus?
    var scanMode: ScanMode = .continuous

    var body: some View {
        Group {
            if showQRCodeScanner, case .authorized = cameraAuthorizationStatus {
                CodeScannerView(codeTypes: [.qr], scanMode: scanMode, isPaused: scannerPaused?.wrappedValue ?? false, completion: processQRCode)
                    .aspectRatio(1, contentMode: .fit)
                    .cornerRadius(12)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .padding(.horizontal)
            } else {
                Button {
                    switch cameraAuthorizationStatus {
                    case .notDetermined: askCameraAuthorization { showQRCodeScanner = true }
                    case .restricted: ()
                    case .denied: UIApplication.shared.open(appSettingsURL)
                    case .authorized: showQRCodeScanner = true
                    default: askCameraAuthorization { showQRCodeScanner = true }
                    }
                } label: {
                    ZStack {
                        Rectangle()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .foregroundColor(Color.clear)
                        switch cameraAuthorizationStatus {
                        case .authorized, nil: EmptyView()
                        case .restricted: Text("Camera not available")
                        case .denied:  Label("Enable camera access", systemImage: "camera")
                        default: Label("Tap to scan", systemImage: "qrcode")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
                .padding(.horizontal)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .disabled(cameraAuthorizationStatus == .restricted)
            }
        }
        .task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            cameraAuthorizationStatus = status
            if showQRCodeScanner {
                switch status {
                case .notDetermined: await askCameraAuthorizationAsync()
                case .restricted: showQRCodeScanner = false
                case .denied: showQRCodeScanner = false
                case .authorized: ()
                @unknown default: await askCameraAuthorizationAsync()
                }
            }
        }
    }

    func askCameraAuthorizationAsync() async {
        await AVCaptureDevice.requestAccess(for: .video)
        cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    }

    func askCameraAuthorization(_ cb: (() -> Void)? = nil) {
        AVCaptureDevice.requestAccess(for: .video) { allowed in
            cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
            if allowed { cb?() }
        }
    }
}


func linkTextView(_ link: String) -> some View {
    Text(link)
        .lineLimit(1)
        .font(.caption)
        .truncationMode(.middle)
}

struct InfoSheetButton<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var showInfoSheet = false

    var body: some View {
        Button {
            showInfoSheet = true
        } label: {
            Image(systemName: "info.circle")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
        }
        .sheet(isPresented: $showInfoSheet) {
            content
        }
    }
}

func strIsSimplexLink(_ str: String) -> Bool {
    let link = switch xauXatValidateContactInviteLink(str) {
    case .notEnvelope: str
    case let .valid(links, _, _), let .expired(links, _): links.first ?? ""
    case .invalid: ""
    }
    if let parsedMd = parseSimpleXMarkdown(link),
       parsedMd.count == 1,
       case .simplexLink = parsedMd[0].format {
        return true
    } else {
        return false
    }
}

enum ConnectTarget {
    case link(text: String, linkType: SimplexLinkType, linkText: String)
    case name(text: String, nameInfo: SimplexNameInfo)
}

func strConnectTarget(_ str: String) -> ConnectTarget? {
    let link = switch xauXatValidateContactInviteLink(str) {
    case .notEnvelope: str
    case let .valid(links, _, _), let .expired(links, _): links.first ?? ""
    case .invalid: ""
    }
    let parsedMd = parseSimpleXMarkdown(link)
    let links = parsedMd?.filter { $0.format?.isSimplexLink ?? false } ?? []
    return if links.count == 1, case let .simplexLink(showText, linkType, simplexUri, smpHosts) = links[0].format {
        .link(text: showText != nil ? simplexUri : links[0].text, linkType: linkType, linkText: simplexLinkText(linkType, smpHosts))
    } else if links.isEmpty,
              let nameFt = parsedMd?.first(where: { if case .simplexName = $0.format { true } else { false } }),
              case let .simplexName(nameInfo) = nameFt.format {
        .name(text: nameFt.text, nameInfo: nameInfo)
    } else {
        nil
    }
}

struct IncognitoToggle: View {
    @EnvironmentObject var theme: AppTheme
    @Binding var incognitoEnabled: Bool
    @State private var showIncognitoSheet = false

    var body: some View {
        ZStack(alignment: .leading) {
            Image(systemName: incognitoEnabled ? "theatermasks.fill" : "theatermasks")
                .frame(maxWidth: 24, maxHeight: 24, alignment: .center)
                .foregroundColor(incognitoEnabled ? Color.indigo : theme.colors.secondary)
                .font(.system(size: 14))
            Toggle(isOn: $incognitoEnabled) {
                HStack(spacing: 6) {
                    Text("Incognito")
                    Image(systemName: "info.circle")
                        .foregroundColor(theme.colors.primary)
                        .font(.system(size: 14))
                }
                .onTapGesture {
                    showIncognitoSheet = true
                }
            }
            .padding(.leading, 36)
        }
        .sheet(isPresented: $showIncognitoSheet) {
            IncognitoHelp()
        }
    }
}

func sharedProfileInfo(_ incognito: Bool) -> Text {
    let name = ChatModel.shared.currentUser?.displayName ?? ""
    return Text(
        incognito
        ? "A new random profile will be shared."
        : "Your profile **\(name)** will be shared."
    )
}

private func showInvitationLinkConnectingAlert(cleanup: (() -> Void)?) {
    showAlert(
        NSLocalizedString("Already connecting!", comment: "new chat sheet title"),
        message: NSLocalizedString("You are already connecting via this one-time link!", comment: "new chat sheet message"),
        actions: {[
            okCleanupAlertAction(cleanup: cleanup)
        ]}
    )
}

private func showGroupLinkConnectingAlert(groupInfo: GroupInfo?, cleanup: (() -> Void)?) {
    if let groupInfo = groupInfo {
        if groupInfo.businessChat == nil {
            showAlert(
                NSLocalizedString("Group already exists!", comment: "new chat sheet title"),
                message:
                    String.localizedStringWithFormat(
                        NSLocalizedString("You are already joining the group %@.", comment: "new chat sheet message"),
                        groupInfo.displayName
                    ),
                actions: {[
                    okCleanupAlertAction(cleanup: cleanup)
                ]}
            )
        } else {
            showAlert(
                NSLocalizedString("Chat already exists!", comment: "new chat sheet title"),
                message:
                    String.localizedStringWithFormat(
                        NSLocalizedString("You are already connecting to %@.", comment: "new chat sheet message"),
                        groupInfo.displayName
                    ),
                actions: {[
                    okCleanupAlertAction(cleanup: cleanup)
                ]}
            )
        }
    } else {
        showAlert(
            NSLocalizedString("Already joining the group!", comment: "new chat sheet title"),
            message: NSLocalizedString("You are already joining the group via this link.", comment: "new chat sheet message"),
            actions: {[
                okCleanupAlertAction(cleanup: cleanup)
            ]}
        )
    }
}

private func okCleanupAlertAction(cleanup: (() -> Void)?) -> UIAlertAction {
    UIAlertAction(
        title: NSLocalizedString("Ok", comment: "new chat action"),
        style: .default,
        handler: { _ in
            cleanup?()
        }
    )
}

private func showAskCurrentOrIncognitoProfileSheet(
    title: String,
    actionStyle: UIAlertAction.Style = .default,
    connectionLink: CreatedConnLink,
    connectionPlan: ConnectionPlan?,
    ownerVerification: OwnerVerification? = nil,
    xauXatExpiresAt: Date? = nil,
    xauXatPermissions: XauXatContactInvitePermissions? = nil,
    dismiss: Bool,
    cleanup: (() -> Void)?
) {
    showSheet(
        title,
        message: xauXatInvitePolicyMessage(
            ownerVerification: ownerVerification,
            expiresAt: xauXatExpiresAt,
            permissions: xauXatPermissions
        ),
        actions: {[
            UIAlertAction(
                title: NSLocalizedString("Use current profile", comment: "new chat action"),
                style: actionStyle,
                handler: { _ in
                    connectViaLink(connectionLink, connectionPlan: connectionPlan, dismiss: dismiss, incognito: false, xauXatExpiresAt: xauXatExpiresAt, xauXatPermissions: xauXatPermissions, cleanup: cleanup)
                }
            ),
            UIAlertAction(
                title: NSLocalizedString("Use new incognito profile", comment: "new chat action"),
                style: actionStyle,
                handler: { _ in
                    connectViaLink(connectionLink, connectionPlan: connectionPlan, dismiss: dismiss, incognito: true, xauXatExpiresAt: xauXatExpiresAt, xauXatPermissions: xauXatPermissions, cleanup: cleanup)
                }
            ),
            UIAlertAction(
                title: NSLocalizedString("Cancel", comment: "new chat action"),
                style: .default,
                handler: { _ in
                    cleanup?()
                }
            )
        ]}
    )
}

private func showAskCurrentOrIncognitoProfileConnectContactViaAddressSheet(
    contact: Contact,
    dismiss: Bool,
    cleanup: (() -> Void)?
) {
    showSheet(
        String.localizedStringWithFormat(
            NSLocalizedString("Connect with %@", comment: "new chat action"),
            contact.chatViewName
        ),
        actions: {[
            UIAlertAction(
                title: NSLocalizedString("Use current profile", comment: "new chat action"),
                style: .default,
                handler: { _ in
                    connectContactViaAddress_(contact, dismiss: dismiss, incognito: false, cleanup: cleanup)
                }
            ),
            UIAlertAction(
                title: NSLocalizedString("Use new incognito profile", comment: "new chat action"),
                style: .default,
                handler: { _ in
                    connectContactViaAddress_(contact, dismiss: dismiss, incognito: true, cleanup: cleanup)
                }
            ),
            UIAlertAction(
                title: NSLocalizedString("Cancel", comment: "new chat action"),
                style: .default,
                handler: { _ in
                    cleanup?()
                }
            )
        ]}
    )
}

private func showOwnGroupLinkConfirmConnectSheet(
    groupInfo: GroupInfo,
    connectionLink: CreatedConnLink,
    connectionPlan: ConnectionPlan?,
    dismiss: Bool,
    cleanup: (() -> Void)?
) {
    if groupInfo.useRelays {
        showSheet(
            String.localizedStringWithFormat(
                NSLocalizedString("This is your link for channel %@!", comment: "new chat action"),
                groupInfo.displayName
            ),
            actions: {[
                UIAlertAction(
                    title: NSLocalizedString("Open channel", comment: "new chat action"),
                    style: .default,
                    handler: { _ in
                        openKnownGroup(groupInfo, dismiss: dismiss, cleanup: cleanup)
                    }
                ),
                UIAlertAction(
                    title: NSLocalizedString("Cancel", comment: "new chat action"),
                    style: .default,
                    handler: { _ in
                        cleanup?()
                    }
                )
            ]}
        )
    } else {
        showSheet(
            String.localizedStringWithFormat(
                NSLocalizedString("Join your group?\nThis is your link for group %@!", comment: "new chat action"),
                groupInfo.displayName
            ),
            actions: {[
                UIAlertAction(
                    title: NSLocalizedString("Open group", comment: "new chat action"),
                    style: .default,
                    handler: { _ in
                        openKnownGroup(groupInfo, dismiss: dismiss, cleanup: cleanup)
                    }
                ),
                UIAlertAction(
                    title: NSLocalizedString("Use current profile", comment: "new chat action"),
                    style: .destructive,
                    handler: { _ in
                        connectViaLink(connectionLink, connectionPlan: connectionPlan, dismiss: dismiss, incognito: false, cleanup: cleanup)
                    }
                ),
                UIAlertAction(
                    title: NSLocalizedString("Use new incognito profile", comment: "new chat action"),
                    style: .destructive,
                    handler: { _ in
                        connectViaLink(connectionLink, connectionPlan: connectionPlan, dismiss: dismiss, incognito: true, cleanup: cleanup)
                    }
                ),
                UIAlertAction(
                    title: NSLocalizedString("Cancel", comment: "new chat action"),
                    style: .default,
                    handler: { _ in
                        cleanup?()
                    }
                )
            ]}
        )
    }
}

private func showPrepareContactAlert(
    connectionLink: CreatedConnLink,
    contactShortLinkData: ContactShortLinkData,
    ownerVerification: OwnerVerification? = nil,
    xauXatExpiresAt: Date? = nil,
    xauXatPermissions: XauXatContactInvitePermissions? = nil,
    verifiedDomain: SimplexDomain? = nil,
    connectOtherButton: String? = nil,
    connectOtherLink: String? = nil,
    theme: AppTheme,
    dismiss: Bool,
    cleanup: (() -> Void)?
) {
    showOpenChatAlert(
        profileName: contactShortLinkData.profile.displayName,
        profileFullName: contactShortLinkData.profile.fullName,
        profileImage:
            ProfileImage(
                imageStr: contactShortLinkData.profile.image,
                iconName: contactShortLinkData.business
                            ? "briefcase.circle.fill"
                            : contactShortLinkData.profile.peerType == .bot
                            ? "cube.fill"
                            : "person.crop.circle.fill",
                size: alertProfileImageSize
            ),
        profileBadge: contactShortLinkData.localBadge,
        theme: theme,
        information: xauXatInvitePolicyMessage(
            ownerVerification: ownerVerification,
            expiresAt: xauXatExpiresAt,
            permissions: xauXatPermissions
        ),
        cancelTitle: NSLocalizedString("Cancel", comment: "new chat action"),
        confirmTitle: NSLocalizedString("Open new chat", comment: "new chat action"),
        secondTitle: connectOtherButton,
        onCancel: { cleanup?() },
        onConfirm: {
            Task {
                do {
                    let chat = try await apiPrepareContact(connLink: connectionLink, contactShortLinkData: contactShortLinkData, verifiedDomain: verifiedDomain)
                    if case let .direct(contact) = chat.chatInfo,
                       let connectionId = contact.activeConn?.connId,
                       let xauXatPermissions {
                        saveXauXatIncomingInvitePolicy(
                            connectionId: connectionId,
                            expiresAt: xauXatExpiresAt,
                            permissions: xauXatPermissions
                        )
                    }
                    await MainActor.run {
                        ChatModel.shared.addChat(Chat(chat))
                        openKnownChat(chat.id, dismiss: dismiss, cleanup: cleanup)
                    }
                } catch let error {
                    logger.error("showPrepareContactAlert apiPrepareContact error: \(error.localizedDescription)")
                    showAlert(NSLocalizedString("Error opening chat", comment: ""), message: responseError(error))
                    await MainActor.run {
                        cleanup?()
                    }
                }
            }
        },
        onSecond: connectOtherLink.map { link in
            { planAndConnect(link, theme: theme, dismiss: dismiss, cleanup: cleanup) }
        }
    )
}

private func showPrepareGroupAlert(
    connectionLink: CreatedConnLink,
    groupShortLinkInfo: GroupShortLinkInfo?,
    groupShortLinkData: GroupShortLinkData,
    ownerVerification: OwnerVerification? = nil,
    verifiedDomain: SimplexDomain? = nil,
    connectOtherButton: String? = nil,
    connectOtherLink: String? = nil,
    theme: AppTheme,
    dismiss: Bool,
    cleanup: (() -> Void)?
) {
    let isChannel = !(groupShortLinkInfo?.direct ?? true)
    let subscriberCount = groupShortLinkData.publicGroupData.map { "\($0.publicMemberCount) subscribers" }
    showOpenChatAlert(
        profileName: groupShortLinkData.groupProfile.displayName,
        profileFullName: groupShortLinkData.groupProfile.fullName,
        profileImage:
            ProfileImage(
                imageStr: groupShortLinkData.groupProfile.image,
                iconName: isChannel
                            ? "antenna.radiowaves.left.and.right.circle.fill"
                            : "person.2.circle.fill",
                size: alertProfileImageSize
            ),
        theme: theme,
        subtitle: isChannel ? subscriberCount : nil,
        information: ownerVerificationMessage(ownerVerification),
        cancelTitle: NSLocalizedString("Cancel", comment: "new chat action"),
        confirmTitle: isChannel
            ? NSLocalizedString("Open new channel", comment: "new chat action")
            : NSLocalizedString("Open new group", comment: "new chat action"),
        secondTitle: connectOtherButton,
        onCancel: { cleanup?() },
        onConfirm: {
            Task {
                do {
                    let chat = try await apiPrepareGroup(connLink: connectionLink, directLink: groupShortLinkInfo?.direct ?? true, groupShortLinkData: groupShortLinkData, verifiedDomain: verifiedDomain)
                    await MainActor.run {
                        if let relays = groupShortLinkInfo?.groupRelays, !relays.isEmpty,
                           case let .group(gInfo, _) = chat.chatInfo {
                            ChatModel.shared.channelRelayHostnames[gInfo.groupId] = relays
                        }
                        ChatModel.shared.addChat(Chat(chat))
                        openKnownChat(chat.id, dismiss: dismiss, cleanup: cleanup)
                    }
                } catch let error {
                    logger.error("showPrepareGroupAlert apiPrepareGroup error: \(error.localizedDescription)")
                    showAlert(NSLocalizedString(isChannel ? "Error opening channel" : "Error opening group", comment: "alert title"), message: responseError(error))
                    await MainActor.run {
                        cleanup?()
                    }
                }
            }
        },
        onSecond: connectOtherLink.map { link in
            { planAndConnect(link, theme: theme, dismiss: dismiss, cleanup: cleanup) }
        }
    )
}

private func showOpenKnownContactAlert(
    _ contact: Contact,
    theme: AppTheme,
    dismiss: Bool,
    connectOtherButton: String? = nil,
    connectOtherLink: String? = nil
) {
    showOpenChatAlert(
        profileName: contact.profile.displayName,
        profileFullName: contact.profile.fullName,
        profileImage:
            ProfileImage(
                imageStr: contact.profile.image,
                iconName: contact.chatIconName,
                size: alertProfileImageSize
            ),
        profileBadge: contact.active ? contact.profile.localBadge : nil,
        theme: theme,
        cancelTitle: NSLocalizedString("Cancel", comment: "new chat action"),
        confirmTitle:
            contact.nextConnectPrepared
            ? NSLocalizedString("Open new chat", comment: "new chat action")
            : NSLocalizedString("Open chat", comment: "new chat action"),
        secondTitle: connectOtherButton,
        onConfirm: {
            openKnownContact(contact, dismiss: dismiss, cleanup: nil)
        },
        onSecond: connectOtherLink.map { link in
            { planAndConnect(link, theme: theme, dismiss: dismiss) }
        }
    )
}

private func showOpenKnownGroupAlert(
    _ groupInfo: GroupInfo,
    theme: AppTheme,
    dismiss: Bool,
    connectOtherButton: String? = nil,
    connectOtherLink: String? = nil
) {
    let subscriberCount = groupInfo.groupSummary.publicMemberCount.map { "\($0) subscribers" }
    showOpenChatAlert(
        profileName: groupInfo.groupProfile.displayName,
        profileFullName: groupInfo.groupProfile.fullName,
        profileImage:
            ProfileImage(
                imageStr: groupInfo.groupProfile.image,
                iconName: groupInfo.chatIconName,
                size: alertProfileImageSize
            ),
        theme: theme,
        subtitle: groupInfo.useRelays ? subscriberCount : nil,
        cancelTitle: NSLocalizedString("Cancel", comment: "new chat action"),
        confirmTitle:
            groupInfo.useRelays
            ? ( groupInfo.nextConnectPrepared
                ? NSLocalizedString("Open new channel", comment: "new chat action")
                : NSLocalizedString("Open channel", comment: "new chat action")
              )
            : groupInfo.businessChat == nil
            ? ( groupInfo.nextConnectPrepared
                ? NSLocalizedString("Open new group", comment: "new chat action")
                : NSLocalizedString("Open group", comment: "new chat action")
              )
            : ( groupInfo.nextConnectPrepared
                ? NSLocalizedString("Open new chat", comment: "new chat action")
                : NSLocalizedString("Open chat", comment: "new chat action")
              ),
        secondTitle: connectOtherButton,
        onConfirm: {
            openKnownGroup(groupInfo, dismiss: dismiss, cleanup: nil)
        },
        onSecond: connectOtherLink.map { link in
            { planAndConnect(link, theme: theme, dismiss: dismiss) }
        }
    )
}

@MainActor
private func requestXauXatGroupAccessCode(
    protectedLink: String,
    linkOwnerSig: LinkOwnerSig?,
    theme: AppTheme,
    dismiss: Bool,
    cleanup: (() -> Void)?,
    filterKnownContact: ((Contact) -> Void)?,
    filterKnownGroup: ((GroupInfo) -> Void)?
) {
    guard let topController = getTopViewController() else {
        cleanup?()
        return
    }
    let alert = UIAlertController(
        title: NSLocalizedString("Group access code", comment: "protected group invite title"),
        message: NSLocalizedString("Enter the code shared separately by the group admin. The code is checked locally and is never sent.", comment: "protected group invite message"),
        preferredStyle: .alert
    )
    alert.addTextField { field in
        field.placeholder = NSLocalizedString("XXXX-XXXX-XXXX", comment: "protected group code placeholder")
        field.isSecureTextEntry = true
        field.textContentType = .oneTimeCode
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
    }
    alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "alert button"), style: .cancel) { _ in
        cleanup?()
    })
    alert.addAction(UIAlertAction(title: NSLocalizedString("Unlock", comment: "protected group invite action"), style: .default) { _ in
        let code = alert.textFields?.first?.text ?? ""
        Task {
            let result = await Task.detached {
                xauXatUnlockProtectedGroupInvite(protectedLink, accessCode: code)
            }.value
            await MainActor.run {
                switch result {
                case let .unlocked(link):
                    planAndConnect(
                        link,
                        linkOwnerSig: linkOwnerSig,
                        theme: theme,
                        dismiss: dismiss,
                        cleanup: cleanup,
                        filterKnownContact: filterKnownContact,
                        filterKnownGroup: filterKnownGroup
                    )
                case let .incorrectCode(retryAfter), let .rateLimited(retryAfter):
                    showAlert(
                        NSLocalizedString("Access denied", comment: "protected group invite error title"),
                        message: String.localizedStringWithFormat(
                            NSLocalizedString("The code is incorrect. Try again in %d second(s).", comment: "protected group invite retry message"),
                            retryAfter
                        )
                    )
                    cleanup?()
                case .expired:
                    showAlert(
                        NSLocalizedString("Group access expired", comment: "protected group invite error title"),
                        message: NSLocalizedString("Ask the group admin for a new access link.", comment: "protected group invite expired message")
                    )
                    cleanup?()
                case .invalid:
                    showAlert(
                        NSLocalizedString("Invalid protected invite", comment: "protected group invite error title"),
                        message: NSLocalizedString("This protected group link is damaged or unsupported.", comment: "protected group invite error message")
                    )
                    cleanup?()
                case .notProtected:
                    cleanup?()
                }
            }
        }
    })
    topController.present(alert, animated: true)
}

// Spec: spec/client/navigation.md#planAndConnect
func planAndConnect(
    _ shortOrFullLink: String,
    linkOwnerSig: LinkOwnerSig? = nil,
    theme: AppTheme,
    dismiss: Bool,
    cleanup: (() -> Void)? = nil,
    filterKnownContact: ((Contact) -> Void)? = nil,
    filterKnownGroup: ((GroupInfo) -> Void)? = nil
) {
    if xauXatIsProtectedGroupInviteLink(shortOrFullLink) {
        Task { @MainActor in
            requestXauXatGroupAccessCode(
                protectedLink: shortOrFullLink,
                linkOwnerSig: linkOwnerSig,
                theme: theme,
                dismiss: dismiss,
                cleanup: cleanup,
                filterKnownContact: filterKnownContact,
                filterKnownGroup: filterKnownGroup
            )
        }
        return
    }
    let effectiveLink: String
    let xauXatExpiresAt: Date?
    let xauXatPermissions: XauXatContactInvitePermissions?
    switch xauXatValidateContactInviteLink(shortOrFullLink) {
    case .notEnvelope:
        effectiveLink = shortOrFullLink
        xauXatExpiresAt = nil
        xauXatPermissions = nil
    case let .valid(links, expiresAt, permissions):
        effectiveLink = links.randomElement() ?? links[0]
        xauXatExpiresAt = expiresAt
        xauXatPermissions = permissions
    case let .expired(_, expiresAt):
        showAlert(
            NSLocalizedString("Invite expired", comment: "alert title"),
            message: String.localizedStringWithFormat(
                NSLocalizedString("This authenticated invite expired on %@. Ask its creator for a new one.", comment: "expired invite alert"),
                expiresAt.formatted(date: .abbreviated, time: .shortened)
            )
        )
        cleanup?()
        return
    case .invalid:
        showAlert(
            NSLocalizedString("Invalid invite", comment: "alert title"),
            message: NSLocalizedString("The XauXat invite signature could not be verified.", comment: "invalid invite alert")
        )
        cleanup?()
        return
    }
    switch strConnectTarget(effectiveLink) {
    case let .link(_, linkType, _):
        if linkType == .relay {
            showAlert(
                NSLocalizedString("Relay address", comment: "alert title"),
                message: NSLocalizedString("This is a chat relay address, it cannot be used to connect.", comment: "alert message")
            )
            cleanup?()
            return
        }
    // A SimplexName falls through to apiConnectPlan, which resolves it on the
    // core (the /_connect plan command accepts a name target, not only a link).
    case .name, .none: break
    }
    ConnectProgressManager.shared.cancelConnectProgress()
    let inProgress = BoxedValue(true)
    connectTask(inProgress)
    ConnectProgressManager.shared.startConnectProgress(NSLocalizedString("Loading profile…", comment: "in progress text")) {
        inProgress.boxedValue = false
        cleanup?()
    }

    func connectTask(_ inProgress: BoxedValue<Bool>) {
        Task {
            let result = await apiConnectPlan(connLink: effectiveLink, linkOwnerSig: linkOwnerSig, inProgress: inProgress)
            await MainActor.run {
                ConnectProgressManager.shared.stopConnectProgress()
            }
            if !inProgress.boxedValue { return }
            if let result {
                let connectionLink = result.connLink
                let connectionPlan = result.connectionPlan
                let planSimplexName = result.planSimplexName
                // the name can also resolve to the other kind; its type picks the verb, its short form the label and target
                let connectOtherLink = result.otherSimplexName?.shortStr
                let connectOtherButton: String? = result.otherSimplexName.map { info in
                    String.localizedStringWithFormat(
                        info.nameType == .publicGroup
                            ? NSLocalizedString("Join channel %@", comment: "new chat action")
                            : NSLocalizedString("Connect to %@", comment: "new chat action"),
                        info.shortStr
                    )
                }
                switch connectionPlan {
                case let .invitationLink(ilp):
                    switch ilp {
                    case let .ok(contactSLinkData_, ownerVerification):
                        if let contactSLinkData = contactSLinkData_ {
                            logger.debug("planAndConnect, .invitationLink, .ok, short link data present")
                            await MainActor.run {
                                showPrepareContactAlert(
                                    connectionLink: connectionLink,
                                    contactShortLinkData: contactSLinkData,
                                    ownerVerification: ownerVerification,
                                    xauXatExpiresAt: xauXatExpiresAt,
                                    xauXatPermissions: xauXatPermissions,
                                    theme: theme,
                                    dismiss: dismiss,
                                    cleanup: cleanup
                                )
                            }
                        } else {
                            logger.debug("planAndConnect, .invitationLink, .ok, no short link data")
                            await MainActor.run {
                                showAskCurrentOrIncognitoProfileSheet(
                                    title: NSLocalizedString("Connect via one-time link", comment: "new chat sheet title"),
                                    connectionLink: connectionLink,
                                    connectionPlan: connectionPlan,
                                    ownerVerification: ownerVerification,
                                    xauXatExpiresAt: xauXatExpiresAt,
                                    xauXatPermissions: xauXatPermissions,
                                    dismiss: dismiss,
                                    cleanup: cleanup
                                )
                            }
                        }
                    case .ownLink:
                        logger.debug("planAndConnect, .invitationLink, .ownLink")
                        await MainActor.run {
                            showAskCurrentOrIncognitoProfileSheet(
                                title: NSLocalizedString("Connect to yourself?\nThis is your own one-time link!", comment: "new chat sheet title"),
                                actionStyle: .destructive,
                                connectionLink: connectionLink,
                                connectionPlan: connectionPlan,
                                dismiss: dismiss,
                                cleanup: cleanup
                            )
                        }
                    case let .connecting(contact_):
                        logger.debug("planAndConnect, .invitationLink, .connecting")
                        await MainActor.run {
                            if let contact = contact_ {
                                if let f = filterKnownContact {
                                    f(contact)
                                } else {
                                    showOpenKnownContactAlert(contact, theme: theme, dismiss: dismiss)
                                }
                            } else {
                                showInvitationLinkConnectingAlert(cleanup: cleanup)
                            }
                        }
                    case let .known(contact):
                        logger.debug("planAndConnect, .invitationLink, .known")
                        await MainActor.run {
                            if let f = filterKnownContact {
                                f(contact)
                            } else {
                                showOpenKnownContactAlert(contact, theme: theme, dismiss: dismiss)
                            }
                        }
                    }
                case let .contactAddress(cap):
                    switch cap {
                    case let .ok(contactSLinkData_, ownerVerification):
                        if let contactSLinkData = contactSLinkData_ {
                            logger.debug("planAndConnect, .contactAddress, .ok, short link data present")
                            await MainActor.run {
                                showPrepareContactAlert(
                                    connectionLink: connectionLink,
                                    contactShortLinkData: contactSLinkData,
                                    ownerVerification: ownerVerification,
                                    verifiedDomain: planSimplexName?.nameDomain,
                                    connectOtherButton: connectOtherButton,
                                    connectOtherLink: connectOtherLink,
                                    theme: theme,
                                    dismiss: dismiss,
                                    cleanup: cleanup
                                )
                            }
                        } else {
                            logger.debug("planAndConnect, .contactAddress, .ok, no short link data")
                            await MainActor.run {
                                showAskCurrentOrIncognitoProfileSheet(
                                    title: NSLocalizedString("Connect via contact address", comment: "new chat sheet title"),
                                    connectionLink: connectionLink,
                                    connectionPlan: connectionPlan,
                                    ownerVerification: ownerVerification,
                                    dismiss: dismiss,
                                    cleanup: cleanup
                                )
                            }
                        }
                    case .ownLink:
                        logger.debug("planAndConnect, .contactAddress, .ownLink")
                        await MainActor.run {
                            showAskCurrentOrIncognitoProfileSheet(
                                title: NSLocalizedString("Connect to yourself?\nThis is your own SimpleX address!", comment: "new chat sheet title"),
                                actionStyle: .destructive,
                                connectionLink: connectionLink,
                                connectionPlan: connectionPlan,
                                dismiss: dismiss,
                                cleanup: cleanup
                            )
                        }
                    case .connectingConfirmReconnect:
                        logger.debug("planAndConnect, .contactAddress, .connectingConfirmReconnect")
                        await MainActor.run {
                            showAskCurrentOrIncognitoProfileSheet(
                                title: NSLocalizedString("You have already requested connection!\nRepeat connection request?", comment: "new chat sheet title"),
                                actionStyle: .destructive,
                                connectionLink: connectionLink,
                                connectionPlan: connectionPlan,
                                dismiss: dismiss,
                                cleanup: cleanup
                            )
                        }
                    case let .connectingProhibit(contact):
                        logger.debug("planAndConnect, .contactAddress, .connectingProhibit")
                        await MainActor.run {
                            if let f = filterKnownContact {
                                f(contact)
                            } else {
                                showOpenKnownContactAlert(contact, theme: theme, dismiss: dismiss, connectOtherButton: connectOtherButton, connectOtherLink: connectOtherLink)
                            }
                        }
                    case let .known(contact):
                        logger.debug("planAndConnect, .contactAddress, .known")
                        await MainActor.run {
                            if ChatModel.shared.getContactChat(contact.contactId) == nil {
                                ChatModel.shared.addChat(Chat(chatInfo: .direct(contact: contact)))
                            }
                            if let f = filterKnownContact {
                                f(contact)
                            } else {
                                showOpenKnownContactAlert(contact, theme: theme, dismiss: dismiss, connectOtherButton: connectOtherButton, connectOtherLink: connectOtherLink)
                            }
                        }
                    case let .contactViaAddress(contact):
                        logger.debug("planAndConnect, .contactAddress, .contactViaAddress")
                        await MainActor.run {
                            showAskCurrentOrIncognitoProfileConnectContactViaAddressSheet(
                                contact: contact,
                                dismiss: dismiss,
                                cleanup: cleanup
                            )
                        }
                    }
                case let .groupLink(glp):
                    switch glp {
                    case let .ok(groupShortLinkInfo_, groupSLinkData_, ownerVerification):
                        if let groupSLinkData = groupSLinkData_ {
                            logger.debug("planAndConnect, .groupLink, .ok, short link data present")
                            await MainActor.run {
                                showPrepareGroupAlert(
                                    connectionLink: connectionLink,
                                    groupShortLinkInfo: groupShortLinkInfo_,
                                    groupShortLinkData: groupSLinkData,
                                    ownerVerification: ownerVerification,
                                    verifiedDomain: planSimplexName?.nameDomain,
                                    connectOtherButton: connectOtherButton,
                                    connectOtherLink: connectOtherLink,
                                    theme: theme,
                                    dismiss: dismiss,
                                    cleanup: cleanup
                                )
                            }
                        } else {
                            logger.debug("planAndConnect, .groupLink, .ok, no short link data")
                            await MainActor.run {
                                showAskCurrentOrIncognitoProfileSheet(
                                    title: NSLocalizedString("Join group", comment: "new chat sheet title"),
                                    connectionLink: connectionLink,
                                    connectionPlan: connectionPlan,
                                    ownerVerification: ownerVerification,
                                    dismiss: dismiss,
                                    cleanup: cleanup
                                )
                            }
                        }
                    case let .ownLink(groupInfo):
                        logger.debug("planAndConnect, .groupLink, .ownLink")
                        await MainActor.run {
                            if let f = filterKnownGroup {
                                f(groupInfo)
                            }
                            showOwnGroupLinkConfirmConnectSheet(
                                groupInfo: groupInfo,
                                connectionLink: connectionLink,
                                connectionPlan: connectionPlan,
                                dismiss: dismiss,
                                cleanup: cleanup
                            )
                        }
                    case .connectingConfirmReconnect:
                        logger.debug("planAndConnect, .groupLink, .connectingConfirmReconnect")
                        await MainActor.run {
                            showAskCurrentOrIncognitoProfileSheet(
                                title: NSLocalizedString("You are already joining the group!\nRepeat join request?", comment: "new chat sheet title"),
                                actionStyle: .destructive,
                                connectionLink: connectionLink,
                                connectionPlan: connectionPlan,
                                dismiss: dismiss,
                                cleanup: cleanup
                            )
                        }
                    case let .connectingProhibit(groupInfo_):
                        logger.debug("planAndConnect, .groupLink, .connectingProhibit")
                        await MainActor.run {
                            showGroupLinkConnectingAlert(groupInfo: groupInfo_, cleanup: cleanup)
                        }
                    case let .known(groupInfo):
                        logger.debug("planAndConnect, .groupLink, .known")
                        await MainActor.run {
                            if ChatModel.shared.getGroupChat(groupInfo.groupId) == nil {
                                ChatModel.shared.addChat(Chat(chatInfo: .group(groupInfo: groupInfo, groupChatScope: nil)))
                            }
                            if let f = filterKnownGroup {
                                f(groupInfo)
                            } else {
                                showOpenKnownGroupAlert(groupInfo, theme: theme, dismiss: dismiss, connectOtherButton: connectOtherButton, connectOtherLink: connectOtherLink)
                            }
                        }
                    case let .noRelays(groupSLinkData_):
                        logger.debug("planAndConnect, .groupLink, .noRelays")
                        await MainActor.run {
                            if let groupSLinkData = groupSLinkData_ {
                                showOpenChatAlert(
                                    profileName: groupSLinkData.groupProfile.displayName,
                                    profileFullName: groupSLinkData.groupProfile.fullName,
                                    profileImage:
                                        ProfileImage(
                                            imageStr: groupSLinkData.groupProfile.image,
                                            iconName: "antenna.radiowaves.left.and.right.circle.fill",
                                            size: alertProfileImageSize
                                        ),
                                    theme: theme,
                                    subtitle: NSLocalizedString("Channel has no active relays. Please try to join later.", comment: "alert subtitle"),
                                    cancelTitle: NSLocalizedString("OK", comment: "alert button"),
                                    confirmTitle: nil,
                                    onCancel: { cleanup?() }
                                )
                            } else {
                                showAlert(
                                    NSLocalizedString("Channel temporarily unavailable", comment: "alert title"),
                                    message: NSLocalizedString("Channel has no active relays. Please try to join later.", comment: "alert message")
                                )
                                cleanup?()
                            }
                        }
                    case let .updateRequired(groupSLinkData_):
                        logger.debug("planAndConnect, .groupLink, .updateRequired")
                        await MainActor.run {
                            if let groupSLinkData = groupSLinkData_ {
                                showOpenChatAlert(
                                    profileName: groupSLinkData.groupProfile.displayName,
                                    profileFullName: groupSLinkData.groupProfile.fullName,
                                    profileImage:
                                        ProfileImage(
                                            imageStr: groupSLinkData.groupProfile.image,
                                            iconName: "person.2.circle.fill",
                                            size: alertProfileImageSize
                                        ),
                                    theme: theme,
                                    subtitle: NSLocalizedString("This group requires a newer version of the app. Please update the app to join.", comment: "alert subtitle"),
                                    cancelTitle: NSLocalizedString("OK", comment: "alert button"),
                                    confirmTitle: nil,
                                    onCancel: { cleanup?() }
                                )
                            } else {
                                showAlert(
                                    NSLocalizedString("App update required", comment: "alert title"),
                                    message: NSLocalizedString("This group requires a newer version of the app. Please update the app to join.", comment: "alert message")
                                )
                                cleanup?()
                            }
                        }
                    }
                case let .error(chatError):
                    logger.debug("planAndConnect, .error \(chatErrorString(chatError))")
                    showAskCurrentOrIncognitoProfileSheet(
                        title: NSLocalizedString("Connect via link", comment: "new chat sheet title"),
                        connectionLink: connectionLink,
                        connectionPlan: nil,
                        dismiss: dismiss,
                        cleanup: cleanup
                    )
                }
            } else if let cleanup {
                await MainActor.run { cleanup() }
            }
        }
    }
}

private func connectContactViaAddress_(_ contact: Contact, dismiss: Bool, incognito: Bool, cleanup: (() -> Void)? = nil) {
    Task {
        if dismiss {
            DispatchQueue.main.async {
                dismissAllSheets(animated: true)
            }
        }
        let ok = await connectContactViaAddress(contact.contactId, incognito, showAlert: { AlertManager.shared.showAlert($0) })
        if ok {
            AlertManager.shared.showAlert(connReqSentAlert(.contact))
        }
        cleanup?()
    }
}

private func connectViaLink(
    _ connectionLink: CreatedConnLink,
    connectionPlan: ConnectionPlan?,
    dismiss: Bool,
    incognito: Bool,
    xauXatExpiresAt: Date? = nil,
    xauXatPermissions: XauXatContactInvitePermissions? = nil,
    cleanup: (() -> Void)?
) {
    Task {
        if let (connReqType, pcc) = await apiConnect(incognito: incognito, connLink: connectionLink) {
            if let xauXatPermissions {
                saveXauXatIncomingInvitePolicy(
                    connectionId: pcc.pccConnId,
                    expiresAt: xauXatExpiresAt,
                    permissions: xauXatPermissions
                )
            }
            await MainActor.run {
                ChatModel.shared.updateContactConnection(pcc)
            }
            let crt: ConnReqType
            crt = if let plan = connectionPlan {
                planToConnReqType(plan) ?? connReqType
            } else {
                connReqType
            }
            DispatchQueue.main.async {
                if dismiss {
                    dismissAllSheets(animated: true) {
                        AlertManager.shared.showAlert(connReqSentAlert(crt))
                    }
                } else {
                    AlertManager.shared.showAlert(connReqSentAlert(crt))
                }
            }
        } else {
            if dismiss {
                DispatchQueue.main.async {
                    dismissAllSheets(animated: true)
                }
            }
        }
        cleanup?()
    }
}

private func saveXauXatIncomingInvitePolicy(
    connectionId: Int64,
    expiresAt: Date?,
    permissions: XauXatContactInvitePermissions
) {
    _ = xauXatSaveContactInvitePolicy(XauXatContactInvitePolicy(
        connectionId: connectionId,
        createdAt: .now,
        expiresAt: expiresAt,
        permissions: permissions
    ))
}

func openKnownContact(_ contact: Contact, dismiss: Bool, cleanup: (() -> Void)?) {
    if let c = ChatModel.shared.getContactChat(contact.contactId) {
        openKnownChat(c.id, dismiss: dismiss, cleanup: cleanup)
    }
}

func openKnownGroup(_ groupInfo: GroupInfo, dismiss: Bool, cleanup: (() -> Void)?) {
    if let g = ChatModel.shared.getGroupChat(groupInfo.groupId) {
        openKnownChat(g.id, dismiss: dismiss, cleanup: cleanup)
    }
}

func openKnownChat(_ chatId: ChatId, dismiss: Bool, cleanup: (() -> Void)?) {
    if dismiss {
        dismissAllSheets(animated: true) {
            ItemsModel.shared.loadOpenChat(chatId) {
                cleanup?()
            }
        }
    } else {
        ItemsModel.shared.loadOpenChat(chatId) {
            cleanup?()
        }
    }
}

func contactAlreadyConnectingAlert(_ contact: Contact) -> Alert {
    mkAlert(
        title: "Contact already exists",
        message: "You are already connecting to \(contact.displayName)."
    )
}

func groupAlreadyExistsAlert(_ groupInfo: GroupInfo) -> Alert {
    groupInfo.businessChat == nil
    ? mkAlert(
        title: "Group already exists",
        message: "You are already in group \(groupInfo.displayName)."
    )
    : mkAlert(
        title: "Chat already exists",
        message: "You are already connected with \(groupInfo.displayName)."
    )
}

enum ConnReqType: Equatable {
    case invitation
    case contact
    case groupLink

    var connReqSentText: LocalizedStringKey {
        switch self {
        case .invitation: return "You will be connected when your contact's device is online, please wait or check later!"
        case .contact: return "You will be connected when your connection request is accepted, please wait or check later!"
        case .groupLink: return "You will be connected when group link host's device is online, please wait or check later!"
        }
    }
}

private func planToConnReqType(_ connectionPlan: ConnectionPlan) -> ConnReqType? {
    switch connectionPlan {
    case .invitationLink: .invitation
    case .contactAddress: .contact
    case .groupLink: .groupLink
    case .error: nil
    }
}

private func ownerVerificationMessage(_ ov: OwnerVerification?) -> String? {
    switch ov {
    case .verified: NSLocalizedString("Link signature verified.", comment: "owner verification")
    case let .failed(reason): String.localizedStringWithFormat(NSLocalizedString("⚠️ Signature verification failed: %@.", comment: "owner verification"), reason)
    case .none: nil
    }
}

private func xauXatInvitePolicyMessage(
    ownerVerification: OwnerVerification?,
    expiresAt: Date?,
    permissions: XauXatContactInvitePermissions?
) -> String? {
    var lines: [String] = []
    if let verification = ownerVerificationMessage(ownerVerification) {
        lines.append(verification)
    }
    if let permissions {
        lines.append(NSLocalizedString("Invite permissions:", comment: "invite permissions heading"))
        lines.append(permissions.messages
                     ? NSLocalizedString("Messages: allowed", comment: "invite permission")
                     : NSLocalizedString("Messages: blocked", comment: "invite permission"))
        lines.append(permissions.calls
                     ? NSLocalizedString("Audio calls: allowed", comment: "invite permission")
                     : NSLocalizedString("Audio calls: blocked", comment: "invite permission"))
    }
    if let expiresAt {
        lines.append(String.localizedStringWithFormat(
            NSLocalizedString("Expires: %@", comment: "invite expiry"),
            expiresAt.formatted(date: .abbreviated, time: .shortened)
        ))
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}

func connReqSentAlert(_ type: ConnReqType) -> Alert {
    return mkAlert(
        title: "Connection request sent!",
        message: type.connReqSentText
    )
}

struct NewChatView_Previews: PreviewProvider {
    static var previews: some View {
        @State var parentAlert: SomeAlert?
        @State var contactConnection: PendingContactConnection? = nil

        NewChatView(
            selection: .invite
        )
    }
}
