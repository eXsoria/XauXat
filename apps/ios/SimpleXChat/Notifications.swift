//
//  Notifications.swift
//  SimpleX
//
//  Created by Evgeny on 28/04/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//
// Spec: spec/services/notifications.md

import Foundation
import UserNotifications
import SwiftUI

public let ntfCategoryContactRequest = "NTF_CAT_CONTACT_REQUEST"
public let ntfCategoryContactConnected = "NTF_CAT_CONTACT_CONNECTED"
public let ntfCategoryMessageReceived = "NTF_CAT_MESSAGE_RECEIVED"
public let ntfCategoryCallInvitation = "NTF_CAT_CALL_INVITATION"
public let ntfCategoryConnectionEvent = "NTF_CAT_CONNECTION_EVENT"
public let ntfCategoryManyEvents = "NTF_CAT_MANY_EVENTS"
public let ntfCategoryCheckMessage = "NTF_CAT_CHECK_MESSAGE"

public let appNotificationId = "chat.simplex.app.notification"

let contactHidden = NSLocalizedString("Contact hidden:", comment: "notification")

private func xauXatIsProtectedProfile(_ user: any UserLike) -> Bool {
    (user as? User)?.hidden == true || xauXatIsProfileProtected(user.userId)
}

private func xauXatCodeLockedNotificationBody(_ item: ChatItem, isChannel: Bool) -> String {
    item.content.text.contains("xauxat-code-lock:v1:")
        ? NSLocalizedString("protected message", comment: "code-locked notification body")
        : hideSecrets(item, isChannel: isChannel)
}

// Spec: spec/services/notifications.md#createContactRequestNtf
public func createContactRequestNtf(_ user: any UserLike, _ contactRequest: UserContactRequest, _ badgeCount: Int) -> UNMutableNotificationContent {
    let protectedProfile = xauXatIsProtectedProfile(user)
    let hideContent = xauXatNtfPreviewMode == .hidden || protectedProfile
    return createNotification(
        categoryIdentifier: ntfCategoryContactRequest,
        title: String.localizedStringWithFormat(
            NSLocalizedString("%@ wants to connect!", comment: "notification title"),
            hideContent ? NSLocalizedString("Somebody", comment: "notification title") : contactRequest.displayName
        ),
        body: String.localizedStringWithFormat(
            NSLocalizedString("Accept contact request from %@?", comment: "notification body"),
            hideContent ? NSLocalizedString("this contact", comment: "notification title") : contactRequest.chatViewName
        ),
        targetContentIdentifier: nil,
        userInfo: ["chatId": contactRequest.id, "contactRequestId": contactRequest.apiId, "userId": user.userId],
        badgeCount: protectedProfile ? nil : badgeCount
    )
}

// Spec: spec/services/notifications.md#createContactConnectedNtf
public func createContactConnectedNtf(_ user: any UserLike, _ contact: Contact, _ badgeCount: Int) -> UNMutableNotificationContent {
    let protectedProfile = xauXatIsProtectedProfile(user)
    let hideContent = xauXatNtfPreviewMode == .hidden || protectedProfile
    return createNotification(
        categoryIdentifier: ntfCategoryContactConnected,
        title: String.localizedStringWithFormat(
            NSLocalizedString("%@ is connected!", comment: "notification title"),
            hideContent ? NSLocalizedString("A new contact", comment: "notification title") : contact.displayName
        ),
        body: String.localizedStringWithFormat(
            NSLocalizedString("You can now chat with %@", comment: "notification body"),
            hideContent ? NSLocalizedString("this contact", comment: "notification title") : contact.chatViewName
        ),
        targetContentIdentifier: contact.id,
        userInfo: ["userId": user.userId],
//            userInfo: ["chatId": contact.id, "contactId": contact.apiId]
        badgeCount: protectedProfile ? nil : badgeCount
    )
}

// Spec: spec/services/notifications.md#createMessageReceivedNtf
public func createMessageReceivedNtf(_ user: any UserLike, _ cInfo: ChatInfo, _ cItem: ChatItem, _ badgeCount: Int) -> UNMutableNotificationContent {
    let previewMode = xauXatNtfPreviewMode
    let protectedProfile = xauXatIsProtectedProfile(user)
    let protected = xauXatIsChatLocked(cInfo.id) || xauXatIsChatHidden(cInfo.id) || protectedProfile
    let hidden = xauXatIsChatHidden(cInfo.id) || protectedProfile
    var title: String
    if protected {
        title = NSLocalizedString("XauXat", comment: "locked conversation notification title")
    } else if case let .group(groupInfo, _) = cInfo, case let .groupRcv(groupMember) = cItem.chatDir {
        title = groupMsgNtfTitle(groupInfo, groupMember, hideContent: previewMode == .hidden)
    } else {
        title = previewMode == .hidden ? contactHidden : "\(cInfo.chatViewName):"
    }
    return createNotification(
        categoryIdentifier: ntfCategoryMessageReceived,
        title: title,
        body: !protected && previewMode == .message ? xauXatCodeLockedNotificationBody(cItem, isChannel: cInfo.isChannel) : NSLocalizedString("new message", comment: "notification"),
        targetContentIdentifier: cInfo.id,
        userInfo: ["userId": user.userId],
//            userInfo: ["chatId": cInfo.id, "chatItemId": cItem.id]
        badgeCount: hidden ? nil : badgeCount
    )
}

// Spec: spec/services/notifications.md#createCallInvitationNtf
public func createCallInvitationNtf(_ invitation: RcvCallInvitation, _ badgeCount: Int, mediaOverride: CallMediaType? = nil) -> UNMutableNotificationContent {
    let text = (mediaOverride ?? invitation.callType.media) == .video
                ? NSLocalizedString("Incoming video call", comment: "notification")
                : NSLocalizedString("Incoming audio call", comment: "notification")
    let hideContent = xauXatNtfPreviewMode == .hidden
    let protectedProfile = invitation.user.hidden || xauXatIsProfileProtected(invitation.user.userId)
    let protected = xauXatIsChatLocked(invitation.contact.id) || xauXatIsChatHidden(invitation.contact.id) || protectedProfile
    let hidden = xauXatIsChatHidden(invitation.contact.id) || protectedProfile
    return createNotification(
        categoryIdentifier: ntfCategoryCallInvitation,
        title: protected ? NSLocalizedString("XauXat", comment: "protected conversation notification title") : hideContent ? contactHidden : "\(invitation.contact.chatViewName):",
        body: protected ? NSLocalizedString("new activity", comment: "protected conversation notification") : text,
        targetContentIdentifier: nil,
        userInfo: ["chatId": invitation.contact.id, "userId": invitation.user.userId],
        badgeCount: hidden ? nil : badgeCount
    )
}

// Spec: spec/services/notifications.md#createConnectionEventNtf
public func createConnectionEventNtf(_ user: User, _ connEntity: ConnectionEntity, _ badgeCount: Int) -> UNMutableNotificationContent {
    let protectedProfile = user.hidden || xauXatIsProfileProtected(user.userId)
    let hideContent = xauXatNtfPreviewMode == .hidden || protectedProfile
    var title: String
    var body: String? = nil
    var targetContentIdentifier: String? = nil
    switch connEntity {
    case let .rcvDirectMsgConnection(_, contact):
        if let contact = contact {
            title = hideContent ? contactHidden : "\(contact.chatViewName):"
            targetContentIdentifier = contact.id
        } else {
            title = NSLocalizedString("New contact:", comment: "notification")
        }
        body = NSLocalizedString("message received", comment: "notification")
    case let .rcvGroupMsgConnection(_, groupInfo, groupMember):
        title = groupMsgNtfTitle(groupInfo, groupMember, hideContent: hideContent)
        body = NSLocalizedString("message received", comment: "notification")
        targetContentIdentifier = groupInfo.id
    case .userContactConnection:
        title = NSLocalizedString("New contact request", comment: "notification")
    }
    let hidden = protectedProfile || (targetContentIdentifier.map(xauXatIsChatHidden) ?? false)
    if let chatID = targetContentIdentifier, xauXatIsChatLocked(chatID) || hidden {
        title = NSLocalizedString("XauXat", comment: "locked conversation notification title")
        body = NSLocalizedString("new message", comment: "notification")
    }
    return createNotification(
        categoryIdentifier: ntfCategoryConnectionEvent,
        title: title,
        body: body,
        targetContentIdentifier: targetContentIdentifier,
        userInfo: ["userId": user.userId],
        badgeCount: hidden ? nil : badgeCount
    )
}

// Spec: spec/services/notifications.md#createErrorNtf
public func createErrorNtf(_ dbStatus: DBMigrationResult, _ badgeCount: Int) -> UNMutableNotificationContent {
    var title: String
    switch dbStatus {
    case .errorNotADatabase:
        title = NSLocalizedString("Encrypted message: no passphrase", comment: "notification")
    case .errorMigration:
        title = NSLocalizedString("Encrypted message: database migration error", comment: "notification")
    case .errorSQL:
        title = NSLocalizedString("Encrypted message: database error", comment: "notification")
    case .errorKeychain:
        title = NSLocalizedString("Encrypted message: keychain error", comment: "notification")
    case .unknown:
        title = NSLocalizedString("Encrypted message: unexpected error", comment: "notification")
    case .invalidConfirmation:
        title = NSLocalizedString("Encrypted message or another event", comment: "notification")
    case .ok:
        title = NSLocalizedString("Encrypted message or another event", comment: "notification")
    }
    return createNotification(
        categoryIdentifier: ntfCategoryConnectionEvent,
        title: title,
        badgeCount: badgeCount
    )
}

// Spec: spec/services/notifications.md#createAppStoppedNtf
public func createAppStoppedNtf(_ badgeCount: Int) -> UNMutableNotificationContent {
    return createNotification(
        categoryIdentifier: ntfCategoryConnectionEvent,
        title: NSLocalizedString("Encrypted message: app is stopped", comment: "notification"),
        badgeCount: badgeCount
    )
}

private func groupMsgNtfTitle(_ groupInfo: GroupInfo, _ groupMember: GroupMember, hideContent: Bool) -> String {
    hideContent
    ? NSLocalizedString("Group message:", comment: "notification")
    : "#\(groupInfo.displayName) \(groupMember.chatViewName):"
}

// Spec: spec/services/notifications.md#createNotification
public func createNotification(
    categoryIdentifier: String,
    title: String,
    subtitle: String? = nil,
    body: String? = nil,
    targetContentIdentifier: String? = nil,
    userInfo: [AnyHashable : Any] = [:],
    badgeCount: Int?
) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.categoryIdentifier = categoryIdentifier
    content.title = title
    if let s = subtitle { content.subtitle = s }
    if let s = body { content.body = s }
    content.targetContentIdentifier = targetContentIdentifier
    content.userInfo = userInfo
    // TODO move logic of adding sound here, so it applies to background notifications too
    content.sound = .default
    if let badgeCount { content.badge = badgeCount as NSNumber }
//        content.interruptionLevel = .active
//        content.relevanceScore = 0.5 // 0-1
    return content
}

// Spec: spec/services/notifications.md#hideSecrets
func hideSecrets(_ cItem: ChatItem, isChannel: Bool = false) -> String {
    if let md = cItem.formattedText {
        var res = ""
        for ft in md {
            if case .secret = ft.format {
                res = res + "..."
            } else {
                res = res + ft.text
            }
        }
        return res
    } else {
        let mc = cItem.content.msgContent
        if case let .report(text, reason) = mc {
            return String.localizedStringWithFormat(NSLocalizedString("Report: %@", comment: "report in notification"), text.isEmpty ? reason.text : text)
        } else {
            return cItem.text(isChannel: isChannel)
        }
    }
}
