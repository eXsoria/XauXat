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
    @State private var groupAccessLifetime: XauXatGroupAccessLifetime = .never
    @State private var customGroupAccessExpiry = Date.now.addingTimeInterval(24 * 60 * 60)
    @State private var oneTimeAccessLifetime: XauXatGroupAccessLifetime = .never
    @State private var customOneTimeAccessExpiry = Date.now.addingTimeInterval(24 * 60 * 60)
    @State private var groupAccessMaximumUses = 1
    @State private var createIndividualGroupAccesses = false
    @State private var individualGroupAccessCount = 2

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
                        if let groupAccessPolicy, !groupAccessPolicy.isExpired() {
                            QRCode(uri: groupAccessPolicy.protectedLink)
                                .id("xauxat-protected-group-qr-\(groupAccessPolicy.rawLinkFingerprint)")
                        } else if groupAccessPolicy == nil {
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
                        if groupAccessPolicy?.isExpired() != true {
                            Button {
                                if !isChannel && groupLink.shouldBeUpgraded {
                                    upgradeAndShareLinkAlert(groupLink: groupLink)
                                } else {
                                    shareGroupLink(groupLink)
                                }
                            } label: {
                                Label("Share link", systemImage: "square.and.arrow.up")
                            }
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
                        title: Text("Revoke group access?"),
                        message: Text("This unused access will stop working immediately. Other individual accesses are not affected."),
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
        .task(id: groupAccessPolicy?.expiresAt) {
            await waitForProtectedGroupAccessExpiry()
        }
        .task(id: oneTimeInvites.compactMap(\.expiresAt).min()) {
            await waitForOneTimeGroupAccessExpiry()
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
        if let groupAccessPolicy, groupAccessPolicy.isExpired() {
            HStack {
                Text("Protected access")
                Spacer()
                Text("Expired")
                    .foregroundColor(theme.colors.secondary)
            }
            if let expiresAt = groupAccessPolicy.expiresAt {
                Text(expiresAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(theme.colors.secondary)
            }
            Button(role: .destructive) {
                Task { await expireProtectedGroupAccess(groupAccessPolicy) }
            } label: {
                Label("Remove expired access", systemImage: "trash")
            }
        } else if let groupAccessPolicy {
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
            if let expiresAt = groupAccessPolicy.expiresAt {
                HStack {
                    Text("Expires")
                    Spacer()
                    Text(expiresAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundColor(theme.colors.secondary)
                }
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
            groupAccessExpiryPicker(lifetime: $groupAccessLifetime, customExpiry: $customGroupAccessExpiry)
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
                groupAccessExpiryPicker(lifetime: $oneTimeAccessLifetime, customExpiry: $customOneTimeAccessExpiry)
                Toggle("Generate individual accesses", isOn: $createIndividualGroupAccesses)
                    .disabled((groupCapacity?.remaining ?? 0) < 2)
                if createIndividualGroupAccesses {
                    Stepper(
                        "Number of accesses: \(individualGroupAccessCount)",
                        value: $individualGroupAccessCount,
                        in: 2...max(2, min(XAUXAT_PLUS_GROUP_MEMBER_LIMIT, groupCapacity?.remaining ?? XAUXAT_PLUS_GROUP_MEMBER_LIMIT))
                    )
                } else {
                    Stepper(
                        "Maximum uses: \(groupAccessMaximumUses)",
                        value: $groupAccessMaximumUses,
                        in: 1...max(1, min(XAUXAT_PLUS_GROUP_MEMBER_LIMIT, groupCapacity?.remaining ?? XAUXAT_PLUS_GROUP_MEMBER_LIMIT))
                    )
                }
                Toggle("Protect with a one-time code", isOn: $protectOneTimeInviteWithCode)
                Text(createIndividualGroupAccesses
                     ? "Each access gets its own ID, link and optional code, and can be shared or revoked independently."
                     : groupAccessMaximumUses == 1
                     ? "The code unlocks only this access and is erased locally as soon as the SimpleX invitation is used."
                     : "XauXat combines independent SimpleX one-time invitations, so simultaneous entries cannot exceed this limit.")
                    .font(.caption)
                    .foregroundColor(theme.colors.secondary)
                Text("Policy: \(configuredAdvancedGroupAccessRules.summary())")
                    .font(.caption)
                    .foregroundColor(theme.colors.secondary)
                if let validationError = advancedGroupAccessValidationError {
                    Text(validationError.message)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            let activeIndividualInvites = oneTimeInvites.filter { $0.state == .active && $0.accessId != nil }
            if !activeIndividualInvites.isEmpty {
                ForEach(activeIndividualInvites) { invite in
                    individualGroupAccessRow(invite)
                }
            } else if let activeInvite = oneTimeInvites.first(where: { $0.state == .active }),
               let shareLink = activeInvite.shareLink {
                QRCode(uri: shareLink)
                    .id("xauxat-one-time-group-qr-\(activeInvite.connectionId)")
                oneTimeInviteStatusRow(activeInvite)
                Button {
                    showShareSheet(items: [groupAccessPolicySummary(activeInvite), shareLink])
                } label: {
                    Label((activeInvite.maxUses ?? 1) > 1 ? "Share limited-use invite" : "Share one-time invite", systemImage: "square.and.arrow.up")
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
                    Label((activeInvite.maxUses ?? 1) > 1 ? "Revoke limited-use invite" : "Revoke one-time invite", systemImage: "xmark.circle")
                }
                ForEach(xauXatOneTimeGroupInviteBundle(connectionId: activeInvite.connectionId).filter { $0.state == .failed }) { failedInvite in
                    Button {
                        if let contactId = failedInvite.contactId {
                            Task { await fulfillXauXatOneTimeGroupInvite(connectionId: failedInvite.connectionId, contactId: contactId) }
                        }
                    } label: {
                        Label("Retry group invitation", systemImage: "arrow.clockwise")
                    }
                }
            } else if !oneTimeInvites.contains(where: { $0.state == .processing }) {
                Button {
                    createOneTimeGroupInvite()
                } label: {
                    Label(
                        createIndividualGroupAccesses
                            ? "Create individual accesses"
                            : groupAccessMaximumUses > 1 ? "Create limited-use invite" : "Create one-time invite",
                        systemImage: "link.badge.plus"
                    )
                }
                .disabled(creatingOneTimeInvite || groupCapacity?.isFull != false)
                .disabled(advancedGroupAccessValidationError != nil)
            }

            ForEach(oneTimeInviteHistory.prefix(5)) { invite in
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

    @ViewBuilder
    private func individualGroupAccessRow(_ invite: XauXatOneTimeGroupInvite) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Access \(individualAccessLabel(invite))")
                Spacer()
                Text(oneTimeInviteStateText(invite.state))
                    .foregroundColor(theme.colors.secondary)
            }
            Text("Role: \(invite.memberRole.text(isChannel: false))")
                .font(.caption)
                .foregroundColor(theme.colors.secondary)
            if let expiresAt = invite.expiresAt {
                Text("Expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(theme.colors.secondary)
            }
        }
        if let shareLink = invite.shareLink {
            Button {
                showShareSheet(items: [groupAccessPolicySummary(invite), shareLink])
            } label: {
                Label("Share access \(individualAccessLabel(invite))", systemImage: "square.and.arrow.up")
            }
        }
        if let code = invite.accessCode {
            HStack {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Label("Copy code", systemImage: "doc.on.doc")
                }
            }
        }
        Button(role: .destructive) {
            alert = .revokeOneTimeInvite(invite.connectionId)
        } label: {
            Label("Revoke access \(individualAccessLabel(invite))", systemImage: "xmark.circle")
        }
    }

    private func individualAccessLabel(_ invite: XauXatOneTimeGroupInvite) -> String {
        String((invite.accessId ?? String(invite.connectionId)).prefix(8)).uppercased()
    }

    private var configuredAdvancedGroupAccessRules: XauXatGroupAccessRules {
        XauXatGroupAccessRules(
            maxUses: createIndividualGroupAccesses ? 1 : groupAccessMaximumUses,
            expiresAt: oneTimeAccessLifetime.expiresAt(custom: customOneTimeAccessExpiry),
            requiresCode: protectOneTimeInviteWithCode,
            individualAccessCount: createIndividualGroupAccesses ? individualGroupAccessCount : nil
        )
    }

    private var advancedGroupAccessValidationError: XauXatGroupAccessRulesError? {
        guard let groupCapacity else { return nil }
        return configuredAdvancedGroupAccessRules.validationError(availableCapacity: groupCapacity.remaining)
    }

    private func groupAccessPolicySummary(_ invite: XauXatOneTimeGroupInvite) -> String {
        let rules = XauXatGroupAccessRules(
            maxUses: invite.maxUses ?? 1,
            expiresAt: invite.expiresAt,
            requiresCode: invite.isProtected,
            individualAccessCount: nil
        )
        let accessLabel = invite.accessId == nil ? nil : individualAccessLabel(invite)
        return "\(invite.groupDisplayName) · \(rules.summary(accessLabel: accessLabel))"
    }

    private func oneTimeInviteStatusRow(_ invite: XauXatOneTimeGroupInvite) -> some View {
        let bundle = xauXatOneTimeGroupInviteBundle(connectionId: invite.connectionId)
        let maximumUses = invite.maxUses ?? 1
        let used = bundle.filter { $0.consumedAt != nil }.count
        let remaining = max(0, maximumUses - used)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(invite.accessId != nil ? "Access \(individualAccessLabel(invite))" : maximumUses > 1 ? "Limited-use invite" : "One-time invite")
                Spacer()
                Text(oneTimeInviteStateText(groupInviteBundleState(bundle, fallback: invite.state)))
                    .foregroundColor(bundle.contains(where: { $0.state == .failed }) ? .red : theme.colors.secondary)
            }
            if maximumUses > 1 {
                Text("Used: \(used) of \(maximumUses) · Remaining: \(remaining)")
                    .font(.caption)
                    .foregroundColor(theme.colors.secondary)
            }
            Text("Role: \(invite.memberRole.text(isChannel: false))")
                .font(.caption)
                .foregroundColor(theme.colors.secondary)
            if invite.usesOneTimeAccessCode {
                Text("Protected by a one-time access code")
                    .font(.caption)
                    .foregroundColor(theme.colors.secondary)
            }
            if let expiresAt = invite.expiresAt {
                Text("Expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(theme.colors.secondary)
            }
            if invite.state == .consumed {
                Text("Link and code invalidated")
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

    private var oneTimeInviteHistory: [XauXatOneTimeGroupInvite] {
        let activeBundleIds = Set(oneTimeInvites.compactMap { invite in
            (invite.state == .active || invite.state == .processing) ? invite.bundleId : nil
        })
        var seenBundles = Set<String>()
        return oneTimeInvites.filter { invite in
            guard invite.state != .active else { return false }
            guard let bundleId = invite.bundleId else { return true }
            guard !activeBundleIds.contains(bundleId) else { return false }
            return seenBundles.insert(bundleId).inserted
        }
    }

    private func groupInviteBundleState(
        _ bundle: [XauXatOneTimeGroupInvite],
        fallback: XauXatOneTimeGroupInviteState
    ) -> XauXatOneTimeGroupInviteState {
        if bundle.contains(where: { $0.state == .processing }) { return .processing }
        if bundle.contains(where: { $0.state == .failed }) { return .failed }
        if bundle.contains(where: { $0.state == .active }) { return .active }
        if bundle.allSatisfy({ $0.state == .consumed }) { return .consumed }
        if bundle.contains(where: { $0.state == .expired }) { return .expired }
        if bundle.contains(where: { $0.state == .revoked }) { return .revoked }
        return fallback
    }

    @ViewBuilder
    private func groupAccessExpiryPicker(
        lifetime: Binding<XauXatGroupAccessLifetime>,
        customExpiry: Binding<Date>
    ) -> some View {
        Picker("Expires", selection: lifetime) {
            ForEach(XauXatGroupAccessLifetime.allCases) { value in
                Text(value.label).tag(value)
            }
        }
        if lifetime.wrappedValue == .custom {
            DatePicker(
                "Expiry date",
                selection: customExpiry,
                in: Date.now...,
                displayedComponents: [.date, .hourAndMinute]
            )
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
                let expiresAt = groupAccessLifetime.expiresAt(custom: customGroupAccessExpiry)
                let policy = await Task.detached {
                    xauXatCreateGroupAccessPolicy(groupId: groupId, rawLink: rawLink, expiresAt: expiresAt)
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
            var created: [(CreatedConnLink, PendingContactConnection)] = []
            do {
                let rules = configuredAdvancedGroupAccessRules
                guard rules.validationError(availableCapacity: groupCapacity?.remaining ?? 0) == nil else {
                    throw XauXatGroupAccessSetupError.inviteCreationFailed
                }
                let individualAccesses = rules.individualAccessCount != nil
                let requestedUses = rules.requestedUses
                _ = try await apiRequireXauXatGroupCapacity(
                    groupId,
                    adding: requestedUses,
                    allowLargeGroup: canUseLargeGroups
                )
                for _ in 0..<requestedUses {
                    guard let invitation = await apiAddContact(incognito: false) else { break }
                    created.append(invitation)
                }
                guard created.count == requestedUses else { throw XauXatGroupAccessSetupError.inviteCreationFailed }
                let expiresAt = rules.expiresAt
                let invites: [XauXatOneTimeGroupInvite]
                if individualAccesses {
                    let batchId = UUID().uuidString
                    var individualInvites: [XauXatOneTimeGroupInvite] = []
                    for (createdLink, connection) in created {
                        let rawLink = createdLink.simplexChatUri(short: false)
                        guard let signedLink = xauXatSignedContactInviteLink(link: rawLink, expiresAt: expiresAt) else {
                            throw XauXatGroupAccessSetupError.encryptionFailed
                        }
                        let code = rules.requiresCode ? xauXatGenerateGroupAccessCode() : nil
                        guard !rules.requiresCode || code != nil else {
                            throw XauXatGroupAccessSetupError.encryptionFailed
                        }
                        let shareLink: String
                        if let code {
                            guard let protectedLink = await Task.detached(operation: {
                                xauXatProtectedGroupInviteLink(rawLink: signedLink, accessCode: code, expiresAt: expiresAt)
                            }).value else { throw XauXatGroupAccessSetupError.encryptionFailed }
                            shareLink = protectedLink
                        } else {
                            shareLink = signedLink
                        }
                        individualInvites.append(XauXatOneTimeGroupInvite(
                            connectionId: connection.pccConnId,
                            groupId: groupId,
                            groupDisplayName: groupInfo?.displayName ?? "Group",
                            memberRole: groupLinkMemberRole,
                            shareLink: shareLink,
                            accessCode: code,
                            accessCodeIsOneTime: code != nil,
                            expiresAt: expiresAt,
                            maxUses: 1,
                            batchId: batchId,
                            accessId: UUID().uuidString
                        ))
                    }
                    invites = individualInvites
                } else {
                    let rawLinks = created.map { $0.0.simplexChatUri(short: false) }
                    let code = rules.requiresCode ? xauXatGenerateGroupAccessCode() : nil
                    guard !rules.requiresCode || code != nil,
                          let bundledLink = xauXatSignedContactInviteLink(links: rawLinks, expiresAt: expiresAt) else {
                        throw XauXatGroupAccessSetupError.encryptionFailed
                    }
                    let shareLink: String
                    if let code {
                        guard let protectedLink = await Task.detached(operation: {
                            xauXatProtectedGroupInviteLink(rawLink: bundledLink, accessCode: code, expiresAt: expiresAt)
                        }).value else { throw XauXatGroupAccessSetupError.encryptionFailed }
                        shareLink = protectedLink
                    } else {
                        shareLink = bundledLink
                    }
                    let bundleId = requestedUses > 1 ? UUID().uuidString : nil
                    invites = created.map { _, connection in
                        XauXatOneTimeGroupInvite(
                            connectionId: connection.pccConnId,
                            groupId: groupId,
                            groupDisplayName: groupInfo?.displayName ?? "Group",
                            memberRole: groupLinkMemberRole,
                            shareLink: shareLink,
                            accessCode: code,
                            accessCodeIsOneTime: code != nil,
                            expiresAt: expiresAt,
                            bundleId: bundleId,
                            maxUses: requestedUses
                        )
                    }
                }
                guard xauXatSaveOneTimeGroupInvites(invites) else {
                    throw XauXatGroupAccessSetupError.inviteCreationFailed
                }
                await MainActor.run {
                    created.forEach { ChatModel.shared.updateContactConnection($0.1) }
                    creatingOneTimeInvite = false
                    refreshOneTimeInvites()
                    if !individualAccesses, let shareLink = invites.first?.shareLink {
                        showShareSheet(items: [groupAccessPolicySummary(invites[0]), shareLink])
                    }
                }
            } catch {
                for (_, connection) in created {
                    try? await apiDeleteChat(type: .contactConnection, id: connection.apiId)
                }
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
            let bundle = xauXatOneTimeGroupInviteBundle(connectionId: connectionId)
            let revocable = bundle.filter { $0.state == .active || $0.state == .failed }
            do {
                for invite in revocable where invite.coreAccessDeletedAt == nil {
                    try await apiDeleteChat(type: .contactConnection, id: invite.connectionId)
                    _ = xauXatMarkOneTimeGroupInviteCoreDeleted(connectionId: invite.connectionId)
                }
                let refreshed = xauXatOneTimeGroupInviteBundle(connectionId: connectionId)
                guard refreshed.filter({ $0.state == .active || $0.state == .failed })
                    .allSatisfy({ $0.coreAccessDeletedAt != nil }) else {
                    throw XauXatGroupAccessSetupError.inviteCreationFailed
                }
                let revoked = xauXatRevokeOneTimeGroupInviteBundle(connectionId: connectionId)
                await MainActor.run {
                    revoked.forEach { ChatModel.shared.removeChat(":\($0)") }
                    refreshOneTimeInvites()
                }
            } catch {
                await MainActor.run {
                    showErrorAlert(error, NSLocalizedString("Couldn't revoke group access", comment: ""))
                }
            }
        }
    }

    private func waitForProtectedGroupAccessExpiry() async {
        guard let policy = groupAccessPolicy, let expiresAt = policy.expiresAt else { return }
        let delay = expiresAt.timeIntervalSinceNow
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        guard !Task.isCancelled, policy.isExpired() else { return }
        await expireProtectedGroupAccess(policy)
    }

    private func expireProtectedGroupAccess(_ policy: XauXatGroupAccessPolicy) async {
        guard policy.isExpired() else { return }
        do {
            try await apiDeleteGroupLink(policy.groupId)
            _ = xauXatRemoveGroupAccessPolicy(groupId: policy.groupId)
            await MainActor.run {
                groupAccessPolicy = nil
                groupLink = nil
            }
        } catch {
            logger.warning("Unable to remove expired protected group access: \(responseError(error))")
            await MainActor.run { refreshOneTimeInvites() }
        }
    }

    private func waitForOneTimeGroupAccessExpiry() async {
        guard let expiresAt = oneTimeInvites
            .filter({ $0.state == .active })
            .compactMap(\.expiresAt)
            .min() else { return }
        let delay = expiresAt.timeIntervalSinceNow
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        guard !Task.isCancelled else { return }
        await expirePendingXauXatGroupAccesses()
        await MainActor.run { refreshOneTimeInvites() }
    }

    private func refreshProtectedAccessLinkIfNeeded() {
        guard let link = groupLink, let policy = groupAccessPolicy, !policy.isExpired() else { return }
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
        guard let policy = groupAccessPolicy, !policy.isExpired() else { return nil }
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
                if let groupAccessPolicy, groupAccessPolicy.isExpired() {
                    await MainActor.run {
                        showAlert(
                            NSLocalizedString("Group access expired", comment: "alert title"),
                            message: NSLocalizedString("Create a new protected access before sharing.", comment: "alert message")
                        )
                    }
                } else if groupAccessPolicy != nil {
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

private enum XauXatGroupAccessLifetime: Int, CaseIterable, Identifiable {
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
