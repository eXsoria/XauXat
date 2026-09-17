//
//  GroupLinkView.swift
//  SimpleX (iOS)
//
//  Created by JRoberts on 15.10.2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//
// Spec: spec/client/chat-view.md

import SwiftUI
import SimpleXChat

struct GroupLinkView: View {
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var plusEntitlements: XauXatPlusEntitlements
    var groupId: Int64
    @Binding var groupLink: GroupLink?
    @Binding var groupLinkMemberRole: GroupMemberRole
    var showTitle: Bool = false
    var creatingGroup: Bool = false
    var isChannel: Bool = false
    var groupInfo: GroupInfo? = nil
    var composeState: Binding<ComposeState>? = nil
    var linkCreatedCb: (() -> Void)? = nil
    @State private var showSharePicker = false
    @State private var showShortLink = true
    @State private var creatingLink = false
    @State private var alert: GroupLinkAlert?
    @State private var shouldCreate = true
    @State private var groupCapacity: XauXatGroupCapacity?
    @State private var loadingGroupCapacity = false
    @State private var groupAccessPolicy: XauXatGroupAccessPolicy?
    @State private var preparingProtectedAccess = false
    @State private var oneTimeInvites: [XauXatOneTimeGroupInvite] = []
    @State private var creatingOneTimeInvite = false
    @State private var protectOneTimeInviteWithCode = false

    private enum GroupLinkAlert: Identifiable {
        case deleteLink
        case revokeOneTimeInvite(Int64)
        case error(title: LocalizedStringKey, error: LocalizedStringKey?)

        var id: String {
            switch self {
            case .deleteLink: return "deleteLink"
            case let .revokeOneTimeInvite(connectionId): return "revokeOneTimeInvite-\(connectionId)"
            case let .error(title, _): return "error \(title)"
            }
        }
    }

    private enum XauXatGroupAccessSetupError: Error {
        case linkCreationFailed
        case encryptionFailed
        case inviteCreationFailed
    }

    var body: some View {
        ZStack {
            if creatingGroup {
                groupLinkView()
                    .navigationBarBackButtonHidden()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button ("Continue") { linkCreatedCb?() }
                        }
                    }
            } else {
                groupLinkView()
            }
            if creatingLink || preparingProtectedAccess {
                ProgressView()
                    .scaleEffect(2)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func groupLinkView() -> some View {
        List {
            Group {
                if showTitle {
                    Text(isChannel ? "Channel link" : "Group link")
                        .font(.largeTitle)
                        .bold()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isChannel {
                    Text("You can share a link or a QR code - anybody will be able to join the channel.")
                } else {
                    Text("Share a link or QR code to request access. New members are reviewed before joining. This plan supports up to \(currentGroupMemberLimit) members.")
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))

            Section {
                if !isChannel {
                    if loadingGroupCapacity {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Checking group capacity…")
                                .foregroundColor(theme.colors.secondary)
                        }
                    } else if let groupCapacity {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(groupCapacity.occupied) of \(groupCapacity.limit) member spots used")
                            if groupCapacity.isFull {
                                Text("This group is full on the current plan. Existing members and larger imported groups are not changed.")
                                    .foregroundColor(theme.colors.secondary)
                            }
                        }
                    }
                }
                if let groupLink = groupLink {
                    if !isChannel && canOfferGroupAccess {
                        Picker("Initial role", selection: $groupLinkMemberRole) {
                            ForEach([GroupMemberRole.member, GroupMemberRole.observer]) { role in
                                Text(role.text(isChannel: isChannel))
                            }
                        }
                        .frame(height: 36)
                    }
                    if canOfferGroupAccess {
                        if let groupAccessPolicy {
                            QRCode(uri: groupAccessPolicy.protectedLink)
                                .id("xauxat-protected-group-qr-\(groupAccessPolicy.rawLinkFingerprint)")
                        } else {
                            SimpleXCreatedLinkQRCode(link: groupLink.connLinkContact, short: $showShortLink)
                                .id("simplex-qrcode-view-for-\(groupLink.connLinkContact.simplexChatUri(short: showShortLink))")
                        }
                        if !isChannel && groupLink.shouldBeUpgraded {
                            Button {
                                upgradeAndShareLinkAlert()
                            } label: {
                                Label("Upgrade link", systemImage: "arrow.up")
                            }
                        }
                        Button {
                            if !isChannel && groupLink.shouldBeUpgraded {
                                upgradeAndShareLinkAlert(groupLink: groupLink)
                            } else {
                                shareGroupLink(groupLink)
                            }
                        } label: {
                            Label("Share link", systemImage: "square.and.arrow.up")
                        }
                        if groupInfo?.groupProfile.publicGroup != nil && groupAccessPolicy == nil {
                            Button { shareGroupLinkViaChat() } label: {
                                Label("Share via chat", systemImage: "arrowshape.turn.up.forward")
                            }
                        }
                    }

                    if !isChannel {
                        secureGroupAccessRows(groupLink)
                    }

                    if !creatingGroup && !isChannel {
                        Button(role: .destructive) { alert = .deleteLink } label: {
                            Label("Delete link", systemImage: "trash")
                        }
                    }
                } else {
                    Button(action: createGroupLink) {
                        Label("Create link", systemImage: "link.badge.plus")
                    }
                    .disabled(creatingLink || (!isChannel && !canOfferGroupAccess))
                }
            } header: {
                if !isChannel, let groupLink, groupLink.connLinkContact.connShortLink != nil {
                    ToggleShortLinkHeader(text: Text(""), link: groupLink.connLinkContact, short: $showShortLink)
                }
            }
            .alert(item: $alert) { alert in
                switch alert {
                case .deleteLink:
                    return Alert(
                        title: Text(groupAccessPolicy == nil ? "Delete link?" : "Revoke link and access code?"),
                        message: Text("The invite will stop working. All existing group members remain connected."),
                        primaryButton: .destructive(Text("Delete")) {
                            Task {
                                do {
                                    try await apiDeleteGroupLink(groupId)
                                    _ = xauXatRemoveGroupAccessPolicy(groupId: groupId)
                                    await MainActor.run {
                                        groupAccessPolicy = nil
                                        groupLink = nil
                                    }
                                } catch let error {
                                    logger.error("GroupLinkView apiDeleteGroupLink: \(responseError(error))")
                                }
                            }
                        }, secondaryButton: .cancel()
                    )
                case let .revokeOneTimeInvite(connectionId):
                    return Alert(
                        title: Text("Revoke one-time invite?"),
                        message: Text("The unused invite will stop working immediately."),
                        primaryButton: .destructive(Text("Revoke")) {
                            revokeOneTimeInvite(connectionId)
                        }, secondaryButton: .cancel()
                    )
                case let .error(title, error):
                    return mkAlert(title: title, message: error)
                }
            }
            .onChange(of: groupLinkMemberRole) { _ in
                Task {
                    do {
                        groupLink = try await apiGroupLinkMemberRole(groupId, memberRole: groupLinkMemberRole)
                    } catch let error {
                        await MainActor.run {
                            showErrorAlert(error, NSLocalizedString("Error updating group link", comment: ""))
                        }
                    }
                }
            }
            .onChange(of: showShortLink) { _ in
                refreshProtectedAccessLinkIfNeeded()
            }
            .task {
                groupAccessPolicy = xauXatGroupAccessPolicy(groupId: groupId)
                protectOneTimeInviteWithCode = groupAccessPolicy != nil
                refreshOneTimeInvites()
                await prepareGroupLinkView()
                refreshProtectedAccessLinkIfNeeded()
            }

            if !isChannel {
                Section {
                    oneTimeGroupInviteRows()
                } header: {
                    Text("One-time group invite")
                } footer: {
                    Text("The SimpleX core accepts only the first valid use. XauXat then sends that contact an invitation to this group.")
                }
            }
        }
        .modifier(ThemedBackground(grouped: true))
        .onReceive(NotificationCenter.default.publisher(for: .xauXatOneTimeGroupInvitesChanged)) { _ in
            refreshOneTimeInvites()
        }
        .sheet(isPresented: $showSharePicker) {
            if let gInfo = groupInfo {
                shareChannelPicker(groupInfo: gInfo, composeState: composeState)
            }
        }
    }

    private var canOfferGroupAccess: Bool {
        isChannel || groupCapacity?.isFull == false
    }

    private var canUseLargeGroups: Bool {
        plusEntitlements.isAuthorized(for: .largeGroups)
    }

    private var canUseSecureGroupAccess: Bool {
        plusEntitlements.isAuthorized(for: .secureGroupAccess)
    }

    private var canUseOneTimeGroupInvites: Bool {
        plusEntitlements.isAuthorized(for: .oneTimeGroupInvites)
    }

    private var currentGroupMemberLimit: Int {
        canUseLargeGroups ? XAUXAT_PLUS_GROUP_MEMBER_LIMIT : XAUXAT_FREE_GROUP_MEMBER_LIMIT
    }

    @ViewBuilder
    private func secureGroupAccessRows(_ link: GroupLink) -> some View {
        if let groupAccessPolicy {
            VStack(alignment: .leading, spacing: 6) {
                Text("Access code")
                    .foregroundColor(theme.colors.secondary)
                Text(groupAccessPolicy.accessCode)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text("Share this code separately. It is never included in the protected link.")
                    .font(.caption)
                    .foregroundColor(theme.colors.secondary)
            }
            Button {
                UIPasteboard.general.string = groupAccessPolicy.accessCode
            } label: {
                Label("Copy access code", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) { alert = .deleteLink } label: {
                Label("Revoke link and code", systemImage: "xmark.circle")
            }
        } else if canUseSecureGroupAccess {
            Button {
                enableProtectedGroupAccess(link)
            } label: {
                Label("Require access code", systemImage: "lock")
            }
            Text("XauXat generates a strong code. The protected link cannot reveal the SimpleX group link without it.")
                .font(.caption)
                .foregroundColor(theme.colors.secondary)
        } else {
            NavigationLink {
                XauXatPlusView()
            } label: {
                Label("Require access code · Plus", systemImage: "lock.fill")
            }
        }
    }

    @ViewBuilder
    private func oneTimeGroupInviteRows() -> some View {
        if canUseOneTimeGroupInvites {
            if !oneTimeInvites.contains(where: { $0.state == .active || $0.state == .processing }) {
                Toggle("Protect with a one-time code", isOn: $protectOneTimeInviteWithCode)
                Text("The code unlocks only this access and is erased locally as soon as the SimpleX invitation is used.")
                    .font(.caption)
                    .foregroundColor(theme.colors.secondary)
            }
            if let activeInvite = oneTimeInvites.first(where: { $0.state == .active }) {
                QRCode(uri: activeInvite.shareLink)
                    .id("xauxat-one-time-group-qr-\(activeInvite.connectionId)")
                oneTimeInviteStatusRow(activeInvite)
                Button {
                    showShareSheet(items: [activeInvite.shareLink])
                } label: {
                    Label("Share one-time invite", systemImage: "square.and.arrow.up")
                }
                if let code = activeInvite.accessCode {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Access code")
                            .foregroundColor(theme.colors.secondary)
                        Text(code)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Send the code separately from the invite link.")
                            .font(.caption)
                            .foregroundColor(theme.colors.secondary)
                    }
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Label("Copy access code", systemImage: "doc.on.doc")
                    }
                }
                Button(role: .destructive) {
                    alert = .revokeOneTimeInvite(activeInvite.connectionId)
                } label: {
                    Label("Revoke one-time invite", systemImage: "xmark.circle")
                }
            } else if !oneTimeInvites.contains(where: { $0.state == .processing }) {
                Button {
                    createOneTimeGroupInvite()
                } label: {
                    Label("Create one-time invite", systemImage: "link.badge.plus")
                }
                .disabled(creatingOneTimeInvite || groupCapacity?.isFull != false)
            }

            ForEach(oneTimeInvites.filter { $0.state != .active }.prefix(5)) { invite in
                oneTimeInviteStatusRow(invite)
                if invite.state == .failed, let contactId = invite.contactId {
                    Button {
                        Task { await fulfillXauXatOneTimeGroupInvite(connectionId: invite.connectionId, contactId: contactId) }
                    } label: {
                        Label("Retry group invitation", systemImage: "arrow.clockwise")
                    }
                }
            }
        } else {
            NavigationLink {
                XauXatPlusView()
            } label: {
                Label("One-time group invite · Plus", systemImage: "1.circle.fill")
            }
        }
    }

    private func oneTimeInviteStatusRow(_ invite: XauXatOneTimeGroupInvite) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("One-time invite")
                Spacer()
                Text(oneTimeInviteStateText(invite.state))
                    .foregroundColor(invite.state == .failed ? .red : theme.colors.secondary)
            }
            Text("Role: \(invite.memberRole.text(isChannel: false))")
                .font(.caption)
                .foregroundColor(theme.colors.secondary)
            if invite.usesOneTimeAccessCode {
                Text("Protected by a one-time access code")
                    .font(.caption)
                    .foregroundColor(theme.colors.secondary)
            }
            if let lastError = invite.lastError, invite.state == .failed {
                Text(lastError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private func oneTimeInviteStateText(_ state: XauXatOneTimeGroupInviteState) -> String {
        switch state {
        case .active: return NSLocalizedString("Active", comment: "one-time group invite state")
        case .processing: return NSLocalizedString("Processing", comment: "one-time group invite state")
        case .consumed: return NSLocalizedString("Consumed", comment: "one-time group invite state")
        case .failed: return NSLocalizedString("Needs attention", comment: "one-time group invite state")
        case .revoked: return NSLocalizedString("Revoked", comment: "one-time group invite state")
        case .expired: return NSLocalizedString("Expired", comment: "one-time group invite state")
        }
    }

    private func enableProtectedGroupAccess(_: GroupLink) {
        guard canUseSecureGroupAccess else { return }
        preparingProtectedAccess = true
        Task {
            do {
                // Rotate first so any previously shared unprotected copy stops
                // working as soon as protection is enabled.
                try await apiDeleteGroupLink(groupId)
                guard let freshLink = try await apiCreateGroupLink(
                    groupId,
                    memberRole: groupLinkMemberRole,
                    enforceGroupLimit: true,
                    allowLargeGroup: canUseLargeGroups
                ) else {
                    throw XauXatGroupAccessSetupError.linkCreationFailed
                }
                let rawLink = freshLink.connLinkContact.simplexChatUri(short: showShortLink)
                let policy = await Task.detached {
                    xauXatCreateGroupAccessPolicy(groupId: groupId, rawLink: rawLink)
                }.value
                guard let policy, xauXatSaveGroupAccessPolicy(policy) else {
                    try? await apiDeleteGroupLink(groupId)
                    throw XauXatGroupAccessSetupError.encryptionFailed
                }
                await MainActor.run {
                    preparingProtectedAccess = false
                    groupLink = freshLink
                    groupAccessPolicy = policy
                }
            } catch {
                await MainActor.run {
                    preparingProtectedAccess = false
                    groupLink = nil
                    showAlert(
                        NSLocalizedString("Couldn't protect group link", comment: "alert title"),
                        message: NSLocalizedString("The previous link was revoked, but XauXat could not create the protected replacement. Create a new link and try again.", comment: "alert message")
                    )
                }
            }
        }
    }

    private func refreshOneTimeInvites() {
        oneTimeInvites = xauXatOneTimeGroupInvites(groupId: groupId)
    }

    private func createOneTimeGroupInvite() {
        guard canUseOneTimeGroupInvites,
              !oneTimeInvites.contains(where: { $0.state == .active || $0.state == .processing }) else { return }
        creatingOneTimeInvite = true
        Task {
            do {
                _ = try await apiRequireXauXatGroupCapacity(groupId, allowLargeGroup: canUseLargeGroups)
                guard let (createdLink, connection) = await apiAddContact(incognito: false) else {
                    throw XauXatGroupAccessSetupError.inviteCreationFailed
                }
                let rawLink = createdLink.simplexChatUri(short: false)
                let code = protectOneTimeInviteWithCode ? xauXatGenerateGroupAccessCode() : nil
                guard !protectOneTimeInviteWithCode || code != nil else {
                    try? await apiDeleteChat(type: .contactConnection, id: connection.apiId)
                    throw XauXatGroupAccessSetupError.encryptionFailed
                }
                let shareLink: String
                if let code {
                    guard let protectedLink = await Task.detached(operation: {
                        xauXatProtectedGroupInviteLink(rawLink: rawLink, accessCode: code)
                    }).value else {
                        try? await apiDeleteChat(type: .contactConnection, id: connection.apiId)
                        throw XauXatGroupAccessSetupError.encryptionFailed
                    }
                    shareLink = protectedLink
                } else {
                    shareLink = rawLink
                }
                let invite = XauXatOneTimeGroupInvite(
                    connectionId: connection.pccConnId,
                    groupId: groupId,
                    groupDisplayName: groupInfo?.displayName ?? "Group",
                    memberRole: groupLinkMemberRole,
                    shareLink: shareLink,
                    accessCode: code,
                    accessCodeIsOneTime: code != nil
                )
                guard xauXatSaveOneTimeGroupInvite(invite) else {
                    try? await apiDeleteChat(type: .contactConnection, id: connection.apiId)
                    throw XauXatGroupAccessSetupError.inviteCreationFailed
                }
                await MainActor.run {
                    ChatModel.shared.updateContactConnection(connection)
                    creatingOneTimeInvite = false
                    refreshOneTimeInvites()
                    showShareSheet(items: [shareLink])
                }
            } catch {
                await MainActor.run {
                    creatingOneTimeInvite = false
                    showAlert(
                        NSLocalizedString("Couldn't create one-time invite", comment: "alert title"),
                        message: NSLocalizedString("Check the group capacity and try again.", comment: "alert message")
                    )
                }
            }
        }
    }

    private func revokeOneTimeInvite(_ connectionId: Int64) {
        Task {
            do {
                try await apiDeleteChat(type: .contactConnection, id: connectionId)
                _ = xauXatRevokeOneTimeGroupInvite(connectionId: connectionId)
                await MainActor.run {
                    ChatModel.shared.removeChat(":\(connectionId)")
                    refreshOneTimeInvites()
                }
            } catch {
                await MainActor.run {
                    showErrorAlert(error, NSLocalizedString("Couldn't revoke one-time invite", comment: ""))
                }
            }
        }
    }

    private func refreshProtectedAccessLinkIfNeeded() {
        guard let link = groupLink, let policy = groupAccessPolicy else { return }
        let rawLink = link.connLinkContact.simplexChatUri(short: showShortLink)
        guard !xauXatGroupAccessPolicyMatches(policy, rawLink: rawLink) else { return }
        preparingProtectedAccess = true
        Task {
            let refreshed = await Task.detached {
                xauXatRefreshGroupAccessPolicy(policy, rawLink: rawLink)
            }.value
            await MainActor.run {
                preparingProtectedAccess = false
                guard let refreshed, xauXatSaveGroupAccessPolicy(refreshed) else {
                    showAlert(
                        NSLocalizedString("Couldn't refresh protected link", comment: "alert title"),
                        message: NSLocalizedString("Try again before sharing this group invite.", comment: "alert message")
                    )
                    return
                }
                groupAccessPolicy = refreshed
            }
        }
    }

    private func protectedPolicyForSharing(_ link: GroupLink) async -> XauXatGroupAccessPolicy? {
        guard let policy = groupAccessPolicy else { return nil }
        let rawLink = link.connLinkContact.simplexChatUri(short: showShortLink)
        if xauXatGroupAccessPolicyMatches(policy, rawLink: rawLink) { return policy }
        let refreshed = await Task.detached {
            xauXatRefreshGroupAccessPolicy(policy, rawLink: rawLink)
        }.value
        guard let refreshed, xauXatSaveGroupAccessPolicy(refreshed) else { return nil }
        await MainActor.run { groupAccessPolicy = refreshed }
        return refreshed
    }

    private func prepareGroupLinkView() async {
        if isChannel {
            await MainActor.run {
                if groupLink == nil && !creatingLink && shouldCreate { createGroupLink() }
                shouldCreate = false
            }
            return
        }

        await MainActor.run { loadingGroupCapacity = true }
        do {
            if let groupInfo {
                let updated = try await apiEnsureXauXatGroupAdmission(groupInfo)
                await MainActor.run { ChatModel.shared.updateGroup(updated) }
            }
            let capacity = try await apiXauXatGroupCapacity(groupId, allowLargeGroup: canUseLargeGroups)
            await MainActor.run {
                groupCapacity = capacity
                loadingGroupCapacity = false
                if groupLink == nil && !creatingLink && shouldCreate && !capacity.isFull {
                    createGroupLink()
                }
                shouldCreate = false
            }
        } catch {
            await MainActor.run {
                loadingGroupCapacity = false
                shouldCreate = false
                showErrorAlert(error, NSLocalizedString("Couldn't prepare group access", comment: ""))
            }
        }
    }

    private func createGroupLink() {
        Task {
            do {
                creatingLink = true
                let gLink = try await apiCreateGroupLink(
                    groupId,
                    enforceGroupLimit: !isChannel,
                    allowLargeGroup: canUseLargeGroups
                )
                await MainActor.run {
                    creatingLink = false
                    groupLink = gLink
                }
            } catch let error {
                logger.error("GroupLinkView apiCreateGroupLink: \(responseError(error))")
                await MainActor.run {
                    creatingLink = false
                    showErrorAlert(error, NSLocalizedString("Error creating group link", comment: ""))
                }
            }
        }
    }

    private func upgradeAndShareLinkAlert(groupLink: GroupLink? = nil) {
        showAlert(
            NSLocalizedString("Upgrade group link?", comment: "alert message"),
            message: NSLocalizedString("The link will be short, and group profile will be shared via the link.", comment: "alert message"),
            actions: {
                var actions = [UIAlertAction(title: NSLocalizedString("Upgrade", comment: "alert button"), style: .default) { _ in
                    addShortLink(shareOnCompletion: groupLink != nil)
                }]
                if let groupLink {
                    actions.append(UIAlertAction(title: NSLocalizedString("Share old link", comment: "alert button"), style: .default) { _ in
                        shareGroupLink(groupLink)
                    })
                }
                actions.append(cancelAlertAction)
                return actions
            }
        )
    }

    private func addShortLink(shareOnCompletion: Bool = false) {
        Task {
            do {
                if !isChannel {
                    _ = try await apiRequireXauXatGroupCapacity(groupId, allowLargeGroup: canUseLargeGroups)
                }
                creatingLink = true
                let gLink = try await apiAddGroupShortLink(groupId)
                await MainActor.run {
                    creatingLink = false
                    groupLink = gLink
                    if shareOnCompletion, let gLink {
                        shareGroupLink(gLink)
                    }
                }
            } catch let error {
                logger.error("apiAddGroupShortLink: \(responseError(error))")
                await MainActor.run {
                    creatingLink = false
                    showErrorAlert(error, NSLocalizedString("Error adding short link", comment: ""))
                }
            }
        }
    }

    private func shareGroupLink(_ link: GroupLink) {
        Task {
            do {
                if !isChannel {
                    groupCapacity = try await apiRequireXauXatGroupCapacity(groupId, allowLargeGroup: canUseLargeGroups)
                }
                if groupAccessPolicy != nil {
                    guard let policy = await protectedPolicyForSharing(link) else {
                        await MainActor.run {
                            showAlert(
                                NSLocalizedString("Protected link unavailable", comment: "alert title"),
                                message: NSLocalizedString("XauXat could not refresh the protected link. Try again.", comment: "alert message")
                            )
                        }
                        return
                    }
                    await MainActor.run { showShareSheet(items: [policy.protectedLink]) }
                } else {
                    await MainActor.run { link.shareAddress(short: showShortLink) }
                }
            } catch {
                await MainActor.run {
                    showErrorAlert(error, NSLocalizedString("Group link unavailable", comment: ""))
                }
            }
        }
    }

    private func shareGroupLinkViaChat() {
        Task {
            do {
                if !isChannel {
                    groupCapacity = try await apiRequireXauXatGroupCapacity(groupId, allowLargeGroup: canUseLargeGroups)
                }
                await MainActor.run { showSharePicker = true }
            } catch {
                await MainActor.run {
                    showErrorAlert(error, NSLocalizedString("Group link unavailable", comment: ""))
                }
            }
        }
    }
}

struct GroupLinkView_Previews: PreviewProvider {
    static var previews: some View {
        @State var groupLink: GroupLink? = GroupLink(
            userContactLinkId: 1,
            connLinkContact: CreatedConnLink(connFullLink: "https://simplex.chat/contact#/?v=1&smp=smp%3A%2F%2FPQUV2eL0t7OStZOoAsPEV2QYWt4-xilbakvGUGOItUo%3D%40smp6.simplex.im%2FK1rslx-m5bpXVIdMZg9NLUZ_8JBm8xTt%23MCowBQYDK2VuAyEALDeVe-sG8mRY22LsXlPgiwTNs9dbiLrNuA7f3ZMAJ2w%3D", connShortLink: nil),
            shortLinkDataSet: false,
            shortLinkLargeDataSet: false,
            groupLinkId: "abc",
            acceptMemberRole: .member
        )
        @State var noGroupLink: GroupLink? = nil

        return Group {
            GroupLinkView(groupId: 1, groupLink: $groupLink, groupLinkMemberRole: Binding.constant(.member))
            GroupLinkView(groupId: 1, groupLink: $noGroupLink, groupLinkMemberRole: Binding.constant(.member))
        }
    }
}
