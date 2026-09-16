//
//  ContextPendingMemberActionsView.swift
//  SimpleX (iOS)
//
//  Created by spaced4ndy on 02.05.2025.
//  Copyright © 2025 SimpleX Chat. All rights reserved.
//

import SwiftUI
import SimpleXChat

struct ContextPendingMemberActionsView: View {
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var plusEntitlements: XauXatPlusEntitlements
    @Environment(\.dismiss) var dismiss
    var groupInfo: GroupInfo
    var member: GroupMember
    @UserDefault(DEFAULT_TOOLBAR_MATERIAL) private var toolbarMaterial = ToolbarMaterial.defaultMaterial
    @State private var groupCapacity: XauXatGroupCapacity?

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Text("Reject")
                    .foregroundColor(.red)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                showRejectMemberAlert(groupInfo, member, dismiss: dismiss)
            }

            if let groupCapacity {
                ZStack {
                    Text(groupCapacity.isFull ? "Plan limit reached" : "Accept")
                        .foregroundColor(groupCapacity.isFull ? theme.colors.secondary : theme.colors.primary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !groupCapacity.isFull {
                        showAcceptMemberAlert(groupInfo, member, dismiss: dismiss)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(minHeight: 54)
        .frame(maxWidth: .infinity)
        .background(ToolbarMaterial.material(toolbarMaterial))
        .task {
            groupCapacity = try? await apiXauXatGroupCapacity(
                groupInfo.groupId,
                allowLargeGroup: plusEntitlements.isAuthorized(for: .largeGroups)
            )
        }
    }
}

func showRejectMemberAlert(_ groupInfo: GroupInfo, _ member: GroupMember, dismiss: DismissAction? = nil) {
    showAlert(
        title: NSLocalizedString("Reject member?", comment: "alert title"),
        buttonTitle: "Reject",
        buttonAction: { removeMember(groupInfo, member, withMessages: false,  dismiss: dismiss) },
        cancelButton: true
    )
}

@MainActor
func showAcceptMemberAlert(_ groupInfo: GroupInfo, _ member: GroupMember, dismiss: DismissAction? = nil) {
    let allowLargeGroup = XauXatPlusEntitlements.shared.isAuthorized(for: .largeGroups)
    showAlert(
        NSLocalizedString("Accept member", comment: "alert title"),
        message: NSLocalizedString("Member will join the group, accept member?", comment: "alert message"),
        actions: {[
            UIAlertAction(
                title: NSLocalizedString("Accept as member", comment: "alert action"),
                style: .default,
                handler: { _ in
                    acceptMember(groupInfo, member, .member, allowLargeGroup: allowLargeGroup, dismiss: dismiss)
                }
            ),
            UIAlertAction(
                title: NSLocalizedString("Accept as observer", comment: "alert action"),
                style: .default,
                handler: { _ in
                    acceptMember(groupInfo, member, .observer, allowLargeGroup: allowLargeGroup, dismiss: dismiss)
                }
            ),
            cancelAlertAction
        ]}
    )
}

@MainActor
func acceptMember(_ groupInfo: GroupInfo, _ member: GroupMember, _ role: GroupMemberRole, allowLargeGroup: Bool, dismiss: DismissAction? = nil) {
    Task {
        do {
            let (gInfo, acceptedMember) = try await apiAcceptMember(
                groupInfo.groupId,
                member.groupMemberId,
                role,
                allowLargeGroup: allowLargeGroup
            )
            await MainActor.run {
                _ = ChatModel.shared.upsertGroupMember(gInfo, acceptedMember)
                ChatModel.shared.updateGroup(gInfo)
                dismiss?()
            }
        } catch let error {
            logger.error("apiAcceptMember error: \(responseError(error))")
            await MainActor.run {
                showAlert(
                    NSLocalizedString("Error accepting member", comment: "alert title"),
                    message: responseError(error)
                )
            }
        }
    }
}

#Preview {
    ContextPendingMemberActionsView(
        groupInfo: GroupInfo.sampleData,
        member: GroupMember.sampleData
    )
}
