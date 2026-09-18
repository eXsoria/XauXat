//
//  KeyChain.swift
//  SimpleXChat
//
//  Created by Evgeny on 04/09/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import Foundation
import Security
import CryptoKit
import CommonCrypto

private let ACCESS_POLICY: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
private let ACCESS_GROUP: String = "5NN7GUYB6T.chat.simplex.app"
private let DATABASE_PASSWORD_ITEM: String = "databasePassword"
private let DECOY_DATABASE_PASSWORD_ITEM: String = "databasePassword.localProfile"
private let APP_PASSWORD_ITEM: String = "appPassword"
private let SELF_DESTRUCT_PASSWORD_ITEM: String = "selfDestructPassword"
private let DECOY_PASSWORD_ITEM: String = "localProfilePassword"
private let PRIMARY_CONVERSATION_LOCKS_ITEM: String = "conversationLocks"
private let DECOY_CONVERSATION_LOCKS_ITEM: String = "conversationLocks.localProfile"
private let PRIMARY_HIDDEN_CHATS_ITEM: String = "hiddenChats"
private let DECOY_HIDDEN_CHATS_ITEM: String = "hiddenChats.localProfile"
private let PRIMARY_PROTECTED_PROFILES_ITEM: String = "protectedProfiles"
private let DECOY_PROTECTED_PROFILES_ITEM: String = "protectedProfiles.localProfile"
private let PRIMARY_PROTECTED_PROFILE_PASSWORDS_ITEM: String = "protectedProfilePasswords"
private let DECOY_PROTECTED_PROFILE_PASSWORDS_ITEM: String = "protectedProfilePasswords.localProfile"
private let CODE_LOCKED_ATTEMPTS_PREFIX: String = "codeLockedAttempts"
private let PRIMARY_CONTACT_INVITE_POLICIES_ITEM: String = "contactInvitePolicies"
private let DECOY_CONTACT_INVITE_POLICIES_ITEM: String = "contactInvitePolicies.localProfile"
private let CONTACT_INVITE_ENVELOPE_QUERY_ITEM: String = "xau_invite"
private let PRIMARY_EXPIRED_CONTACT_INVITE_ENVELOPES_ITEM: String = "expiredContactInviteEnvelopes"
private let DECOY_EXPIRED_CONTACT_INVITE_ENVELOPES_ITEM: String = "expiredContactInviteEnvelopes.localProfile"
private let PRIMARY_GROUP_ACCESS_POLICIES_ITEM: String = "groupAccessPolicies"
private let DECOY_GROUP_ACCESS_POLICIES_ITEM: String = "groupAccessPolicies.localProfile"
private let PRIMARY_ONE_TIME_GROUP_INVITES_ITEM: String = "oneTimeGroupInvites"
private let DECOY_ONE_TIME_GROUP_INVITES_ITEM: String = "oneTimeGroupInvites.localProfile"
private let GROUP_ACCESS_ATTEMPTS_PREFIX: String = "groupAccessAttempts"
private let GROUP_ACCESS_EXPIRED_PREFIX: String = "groupAccessExpired"

public enum XauXatStorageScope: Sendable {
    case primary
    case decoy
}

private let xauXatStorageScopeLock = NSLock()
private var activeXauXatStorageScope: XauXatStorageScope = .primary

public func xauXatStorageScope() -> XauXatStorageScope {
    xauXatStorageScopeLock.lock()
    defer { xauXatStorageScopeLock.unlock() }
    return activeXauXatStorageScope
}

public func setXauXatStorageScope(_ scope: XauXatStorageScope) {
    xauXatStorageScopeLock.lock()
    activeXauXatStorageScope = scope
    xauXatStorageScopeLock.unlock()
}

public let kcPrimaryDatabasePassword = KeyChainItem(forKey: DATABASE_PASSWORD_ITEM)

public let kcDecoyDatabasePassword = KeyChainItem(forKey: DECOY_DATABASE_PASSWORD_ITEM)

public var kcDatabasePassword: KeyChainItem {
    xauXatStorageScope() == .decoy ? kcDecoyDatabasePassword : kcPrimaryDatabasePassword
}

public let kcAppPassword = KeyChainItem(forKey: APP_PASSWORD_ITEM)

public let kcSelfDestructPassword = KeyChainItem(forKey: SELF_DESTRUCT_PASSWORD_ITEM)

public let kcDecoyPassword = KeyChainItem(forKey: DECOY_PASSWORD_ITEM)

private let kcPrimaryConversationLocks = KeyChainItem(forKey: PRIMARY_CONVERSATION_LOCKS_ITEM)
private let kcDecoyConversationLocks = KeyChainItem(forKey: DECOY_CONVERSATION_LOCKS_ITEM)
private let kcPrimaryHiddenChats = KeyChainItem(forKey: PRIMARY_HIDDEN_CHATS_ITEM)
private let kcDecoyHiddenChats = KeyChainItem(forKey: DECOY_HIDDEN_CHATS_ITEM)
private let kcPrimaryProtectedProfiles = KeyChainItem(forKey: PRIMARY_PROTECTED_PROFILES_ITEM)
private let kcDecoyProtectedProfiles = KeyChainItem(forKey: DECOY_PROTECTED_PROFILES_ITEM)
private let kcPrimaryProtectedProfilePasswords = KeyChainItem(forKey: PRIMARY_PROTECTED_PROFILE_PASSWORDS_ITEM)
private let kcDecoyProtectedProfilePasswords = KeyChainItem(forKey: DECOY_PROTECTED_PROFILE_PASSWORDS_ITEM)
private let kcPrimaryContactInvitePolicies = KeyChainItem(forKey: PRIMARY_CONTACT_INVITE_POLICIES_ITEM)
private let kcDecoyContactInvitePolicies = KeyChainItem(forKey: DECOY_CONTACT_INVITE_POLICIES_ITEM)
private let kcPrimaryGroupAccessPolicies = KeyChainItem(forKey: PRIMARY_GROUP_ACCESS_POLICIES_ITEM)
private let kcDecoyGroupAccessPolicies = KeyChainItem(forKey: DECOY_GROUP_ACCESS_POLICIES_ITEM)
private let kcPrimaryOneTimeGroupInvites = KeyChainItem(forKey: PRIMARY_ONE_TIME_GROUP_INVITES_ITEM)
private let kcDecoyOneTimeGroupInvites = KeyChainItem(forKey: DECOY_ONE_TIME_GROUP_INVITES_ITEM)
private let xauXatContactInvitePoliciesLock = NSLock()
private let xauXatExpiredContactInviteEnvelopesLock = NSLock()
private let xauXatGroupAccessPoliciesLock = NSLock()
private let xauXatOneTimeGroupInvitesLock = NSLock()
private let kcPrimaryExpiredContactInviteEnvelopes = KeyChainItem(forKey: PRIMARY_EXPIRED_CONTACT_INVITE_ENVELOPES_ITEM)
private let kcDecoyExpiredContactInviteEnvelopes = KeyChainItem(forKey: DECOY_EXPIRED_CONTACT_INVITE_ENVELOPES_ITEM)

private var kcConversationLocks: KeyChainItem {
    xauXatStorageScope() == .decoy ? kcDecoyConversationLocks : kcPrimaryConversationLocks
}

public func xauXatLockedChatIDs() -> Set<String> {
    guard let value = kcConversationLocks.get(),
          let data = value.data(using: .utf8),
          let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return Set(ids)
}

public func xauXatIsChatLocked(_ chatID: String) -> Bool {
    xauXatLockedChatIDs().contains(chatID)
}

@discardableResult
public func xauXatSetChatLocked(_ chatID: String, locked: Bool) -> Bool {
    var ids = xauXatLockedChatIDs()
    if locked {
        ids.insert(chatID)
    } else {
        ids.remove(chatID)
    }
    guard !ids.isEmpty else { return kcConversationLocks.remove() }
    guard let data = try? JSONEncoder().encode(ids.sorted()),
          let value = String(data: data, encoding: .utf8) else { return false }
    return kcConversationLocks.set(value)
}

@discardableResult
public func xauXatRemoveConversationLocks(_ scope: XauXatStorageScope) -> Bool {
    switch scope {
    case .primary: kcPrimaryConversationLocks.remove()
    case .decoy: kcDecoyConversationLocks.remove()
    }
}

private var kcHiddenChats: KeyChainItem {
    xauXatStorageScope() == .decoy ? kcDecoyHiddenChats : kcPrimaryHiddenChats
}

public func xauXatHiddenChatIDs() -> Set<String> {
    guard let value = kcHiddenChats.get(),
          let data = value.data(using: .utf8),
          let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return Set(ids)
}

public func xauXatIsChatHidden(_ chatID: String) -> Bool {
    xauXatHiddenChatIDs().contains(chatID)
}

@discardableResult
public func xauXatSetChatHidden(_ chatID: String, hidden: Bool) -> Bool {
    var ids = xauXatHiddenChatIDs()
    if hidden {
        ids.insert(chatID)
    } else {
        ids.remove(chatID)
    }
    guard !ids.isEmpty else { return kcHiddenChats.remove() }
    guard let data = try? JSONEncoder().encode(ids.sorted()),
          let value = String(data: data, encoding: .utf8) else { return false }
    return kcHiddenChats.set(value)
}

@discardableResult
public func xauXatRemoveHiddenChats(_ scope: XauXatStorageScope) -> Bool {
    switch scope {
    case .primary: kcPrimaryHiddenChats.remove()
    case .decoy: kcDecoyHiddenChats.remove()
    }
}

private var kcProtectedProfiles: KeyChainItem {
    xauXatStorageScope() == .decoy ? kcDecoyProtectedProfiles : kcPrimaryProtectedProfiles
}

public func xauXatProtectedProfileIDs() -> Set<Int64> {
    guard let value = kcProtectedProfiles.get(),
          let data = value.data(using: .utf8),
          let ids = try? JSONDecoder().decode([Int64].self, from: data) else { return [] }
    return Set(ids)
}

public func xauXatIsProfileProtected(_ userID: Int64) -> Bool {
    xauXatProtectedProfileIDs().contains(userID)
}

@discardableResult
public func xauXatSyncProtectedProfileIDs(_ userIDs: Set<Int64>) -> Bool {
    guard !userIDs.isEmpty else { return kcProtectedProfiles.remove() }
    guard let data = try? JSONEncoder().encode(userIDs.sorted()),
          let value = String(data: data, encoding: .utf8) else { return false }
    return kcProtectedProfiles.set(value)
}

@discardableResult
public func xauXatRemoveProtectedProfiles(_ scope: XauXatStorageScope) -> Bool {
    switch scope {
    case .primary: kcPrimaryProtectedProfiles.remove()
    case .decoy: kcDecoyProtectedProfiles.remove()
    }
}

private var kcProtectedProfilePasswords: KeyChainItem {
    xauXatStorageScope() == .decoy ? kcDecoyProtectedProfilePasswords : kcPrimaryProtectedProfilePasswords
}

private func xauXatProtectedProfilePasswords() -> [String: String] {
    guard let value = kcProtectedProfilePasswords.get(),
          let data = value.data(using: .utf8),
          let passwords = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
    return passwords
}

public func xauXatProtectedProfilePassword(_ userID: Int64) -> String? {
    xauXatProtectedProfilePasswords()[String(userID)]
}

@discardableResult
public func xauXatSetProtectedProfilePassword(_ userID: Int64, password: String?) -> Bool {
    var passwords = xauXatProtectedProfilePasswords()
    passwords[String(userID)] = password
    guard !passwords.isEmpty else { return kcProtectedProfilePasswords.remove() }
    guard let data = try? JSONEncoder().encode(passwords),
          let value = String(data: data, encoding: .utf8) else { return false }
    return kcProtectedProfilePasswords.set(value)
}

@discardableResult
public func xauXatRemoveProtectedProfilePasswords(_ scope: XauXatStorageScope) -> Bool {
    switch scope {
    case .primary: kcPrimaryProtectedProfilePasswords.remove()
    case .decoy: kcDecoyProtectedProfilePasswords.remove()
    }
}

public enum XauXatContactInviteState: String, Codable, Sendable {
    case active
    case used
    case expired
    case revoked
}

public struct XauXatContactInvitePermissions: Codable, Hashable, Sendable {
    public var messages: Bool
    public var calls: Bool

    public init(messages: Bool = true, calls: Bool = true) {
        self.messages = messages
        self.calls = calls
    }

    public var isRestricted: Bool { !messages || !calls }
}

public struct XauXatContactInvitePolicy: Codable, Hashable, Sendable {
    public var connectionId: Int64
    public var createdAt: Date
    public var expiresAt: Date?
    public var maxObservedAt: Date
    public var state: XauXatContactInviteState
    public var permissions: XauXatContactInvitePermissions?
    public var bundleId: String?
    public var maxUses: Int?

    public init(
        connectionId: Int64,
        createdAt: Date,
        expiresAt: Date? = nil,
        permissions: XauXatContactInvitePermissions? = nil,
        bundleId: String? = nil,
        maxUses: Int? = nil
    ) {
        self.connectionId = connectionId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.maxObservedAt = createdAt
        self.state = .active
        self.permissions = permissions
        self.bundleId = bundleId
        self.maxUses = maxUses
    }

    public var isExpired: Bool { state == .expired }
}

private var kcContactInvitePolicies: KeyChainItem {
    xauXatStorageScope() == .decoy ? kcDecoyContactInvitePolicies : kcPrimaryContactInvitePolicies
}

private func readXauXatContactInvitePolicies() -> [Int64: XauXatContactInvitePolicy] {
    guard let value = kcContactInvitePolicies.get(),
          let data = value.data(using: .utf8),
          let policies = try? JSONDecoder().decode([String: XauXatContactInvitePolicy].self, from: data) else { return [:] }
    return Dictionary(uniqueKeysWithValues: policies.compactMap { key, value in
        Int64(key).map { ($0, value) }
    })
}

@discardableResult
private func writeXauXatContactInvitePolicies(_ policies: [Int64: XauXatContactInvitePolicy]) -> Bool {
    guard !policies.isEmpty else { return kcContactInvitePolicies.remove() }
    let encoded = Dictionary(uniqueKeysWithValues: policies.map { (String($0.key), $0.value) })
    guard let data = try? JSONEncoder().encode(encoded),
          let value = String(data: data, encoding: .utf8) else { return false }
    return kcContactInvitePolicies.set(value)
}

@discardableResult
public func xauXatSaveContactInvitePolicy(_ policy: XauXatContactInvitePolicy) -> Bool {
    xauXatContactInvitePoliciesLock.lock()
    defer { xauXatContactInvitePoliciesLock.unlock() }
    var policies = readXauXatContactInvitePolicies()
    policies[policy.connectionId] = policy
    return writeXauXatContactInvitePolicies(policies)
}

/// Observing a policy advances its trusted local clock. Once the expiry instant
/// has ever been observed, the stored tombstone prevents a manual clock rollback
/// from reactivating the invite.
public func xauXatObserveContactInvitePolicy(
    connectionId: Int64,
    at observedAt: Date = .now
) -> XauXatContactInvitePolicy? {
    xauXatContactInvitePoliciesLock.lock()
    defer { xauXatContactInvitePoliciesLock.unlock() }
    var policies = readXauXatContactInvitePolicies()
    guard var policy = policies[connectionId] else { return nil }
    guard policy.state == .active else { return policy }
    guard let expiresAt = policy.expiresAt else { return policy }
    let trustedObservedAt = max(observedAt, policy.maxObservedAt)
    if trustedObservedAt >= expiresAt {
        policy.maxObservedAt = trustedObservedAt
    } else if observedAt.timeIntervalSince(policy.maxObservedAt) >= 60 {
        policy.maxObservedAt = observedAt
    }
    if policy.maxObservedAt >= expiresAt {
        policy.state = .expired
    }
    policies[connectionId] = policy
    _ = writeXauXatContactInvitePolicies(policies)
    return policy
}

@discardableResult
public func xauXatSetContactInviteState(
    connectionId: Int64,
    state: XauXatContactInviteState,
    at observedAt: Date = .now
) -> XauXatContactInvitePolicy? {
    xauXatContactInvitePoliciesLock.lock()
    defer { xauXatContactInvitePoliciesLock.unlock() }
    var policies = readXauXatContactInvitePolicies()
    guard var policy = policies[connectionId] else { return nil }
    policy.maxObservedAt = max(policy.maxObservedAt, observedAt)
    // Expiry is irreversible. Used and revoked invites are terminal as well.
    if policy.state == .active || policy.state == state {
        policy.state = state
    }
    policies[connectionId] = policy
    _ = writeXauXatContactInvitePolicies(policies)
    return policy
}

public func xauXatContactInvitePolicies(at observedAt: Date = .now) -> [XauXatContactInvitePolicy] {
    xauXatContactInvitePoliciesLock.lock()
    defer { xauXatContactInvitePoliciesLock.unlock() }
    var policies = readXauXatContactInvitePolicies()
    var changed = false
    for (connectionId, var policy) in policies {
        guard policy.state == .active else { continue }
        guard let expiresAt = policy.expiresAt else { continue }
        let trustedObservedAt = max(observedAt, policy.maxObservedAt)
        if trustedObservedAt >= expiresAt {
            policy.maxObservedAt = trustedObservedAt
            changed = true
        } else if observedAt.timeIntervalSince(policy.maxObservedAt) >= 60 {
            policy.maxObservedAt = observedAt
            changed = true
        }
        if policy.maxObservedAt >= expiresAt {
            policy.state = .expired
            changed = true
        }
        policies[connectionId] = policy
    }
    if changed { _ = writeXauXatContactInvitePolicies(policies) }
    return Array(policies.values)
}

public enum XauXatContactInviteEnvelopeResult: Sendable {
    case notEnvelope
    case valid(links: [String], expiresAt: Date?, permissions: XauXatContactInvitePermissions)
    case expired(links: [String], expiresAt: Date)
    case invalid
}

private struct XauXatContactInviteEnvelope: Codable {
    var version: Int
    var link: String
    var expiresAt: Int64?
    var publicKey: String
    var signature: String
    var messages: Bool?
    var calls: Bool?
    var links: [String]?
}

private func xauXatBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func xauXatBase64URLData(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
    return Data(base64Encoded: base64)
}

private func xauXatContactInviteCanonicalData(
    links: [String],
    expiresAt: Int64?,
    permissions: XauXatContactInvitePermissions,
    version: Int
) -> Data {
    let firstLink = links.first ?? ""
    if version == 1, let expiresAt {
        return Data("xauxat-contact-invite-v1\n\(expiresAt)\n\(firstLink)".utf8)
    }
    let prefix = "xauxat-contact-invite-v\(version)\n\(expiresAt.map { String($0) } ?? "never")\n\(permissions.messages ? 1 : 0)\n\(permissions.calls ? 1 : 0)\n"
    return Data((prefix + links.joined(separator: "\n")).utf8)
}

private var kcExpiredContactInviteEnvelopes: KeyChainItem {
    xauXatStorageScope() == .decoy ? kcDecoyExpiredContactInviteEnvelopes : kcPrimaryExpiredContactInviteEnvelopes
}

private func xauXatContactInviteEnvelopeFingerprint(_ encodedEnvelope: String) -> String {
    xauXatBase64URL(Data(SHA256.hash(data: Data(encodedEnvelope.utf8))))
}

private func xauXatExpiredContactInviteEnvelopeFingerprints() -> Set<String> {
    guard let value = kcExpiredContactInviteEnvelopes.get(),
          let data = value.data(using: .utf8),
          let fingerprints = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return Set(fingerprints)
}

private func xauXatMarkContactInviteEnvelopeExpired(_ encodedEnvelope: String) {
    var fingerprints = xauXatExpiredContactInviteEnvelopeFingerprints()
    fingerprints.insert(xauXatContactInviteEnvelopeFingerprint(encodedEnvelope))
    guard let data = try? JSONEncoder().encode(fingerprints.sorted()),
          let value = String(data: data, encoding: .utf8) else { return }
    _ = kcExpiredContactInviteEnvelopes.set(value)
}

public func xauXatSignedContactInviteLink(
    link: String,
    expiresAt: Date?,
    permissions: XauXatContactInvitePermissions = .init()
) -> String? {
    xauXatSignedContactInviteLink(links: [link], expiresAt: expiresAt, permissions: permissions)
}

public func xauXatSignedContactInviteLink(
    links: [String],
    expiresAt: Date?,
    permissions: XauXatContactInvitePermissions = .init()
) -> String? {
    guard let firstLink = links.first, !links.contains(where: { $0.isEmpty }),
          var components = URLComponents(string: firstLink) else { return nil }
    // A fresh signing key per rendered invite avoids introducing a reusable,
    // globally correlatable identifier across otherwise anonymous links.
    let key = P256.Signing.PrivateKey()
    let expiry = expiresAt.map { Int64($0.timeIntervalSince1970) }
    guard let signature = try? key.signature(for: xauXatContactInviteCanonicalData(
        links: links,
        expiresAt: expiry,
        permissions: permissions,
        version: 3
    )) else { return nil }
    let envelope = XauXatContactInviteEnvelope(
        version: 3,
        link: firstLink,
        expiresAt: expiry,
        publicKey: xauXatBase64URL(key.publicKey.x963Representation),
        signature: xauXatBase64URL(signature.rawRepresentation),
        messages: permissions.messages,
        calls: permissions.calls,
        links: links
    )
    guard let envelopeData = try? JSONEncoder().encode(envelope) else { return nil }
    components.fragment = nil
    components.queryItems = [URLQueryItem(name: CONTACT_INVITE_ENVELOPE_QUERY_ITEM, value: xauXatBase64URL(envelopeData))]
    return components.string
}

public func xauXatValidateContactInviteLink(
    _ value: String,
    at observedAt: Date = .now
) -> XauXatContactInviteEnvelopeResult {
    guard let components = URLComponents(string: value),
          let encodedEnvelope = components.queryItems?.first(where: { $0.name == CONTACT_INVITE_ENVELOPE_QUERY_ITEM })?.value else {
        return .notEnvelope
    }
    guard let envelopeData = xauXatBase64URLData(encodedEnvelope),
          let envelope = try? JSONDecoder().decode(XauXatContactInviteEnvelope.self, from: envelopeData),
          (1...3).contains(envelope.version),
          let publicKeyData = xauXatBase64URLData(envelope.publicKey),
          let signatureData = xauXatBase64URLData(envelope.signature),
          let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData),
          let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
          publicKey.isValidSignature(
              signature,
              for: xauXatContactInviteCanonicalData(
                  links: envelope.version >= 3 ? (envelope.links ?? [envelope.link]) : [envelope.link],
                  expiresAt: envelope.expiresAt,
                  permissions: XauXatContactInvitePermissions(
                      messages: envelope.messages ?? true,
                      calls: envelope.calls ?? true
                  ),
                  version: envelope.version
              )
          ) else {
        return .invalid
    }
    let permissions = XauXatContactInvitePermissions(
        messages: envelope.messages ?? true,
        calls: envelope.calls ?? true
    )
    let links = envelope.version >= 3 ? (envelope.links ?? [envelope.link]) : [envelope.link]
    guard !links.isEmpty, !links.contains(where: { $0.isEmpty }) else { return .invalid }
    guard let expiry = envelope.expiresAt else {
        return .valid(links: links, expiresAt: nil, permissions: permissions)
    }
    let expiresAt = Date(timeIntervalSince1970: TimeInterval(expiry))
    let fingerprint = xauXatContactInviteEnvelopeFingerprint(encodedEnvelope)
    if observedAt >= expiresAt || xauXatExpiredContactInviteEnvelopeFingerprints().contains(fingerprint) {
        xauXatExpiredContactInviteEnvelopesLock.lock()
        xauXatMarkContactInviteEnvelopeExpired(encodedEnvelope)
        xauXatExpiredContactInviteEnvelopesLock.unlock()
        return .expired(links: links, expiresAt: expiresAt)
    }
    return .valid(links: links, expiresAt: expiresAt, permissions: permissions)
}

public func xauXatContactInviteBundlePolicies(bundleId: String) -> [XauXatContactInvitePolicy] {
    xauXatContactInvitePolicies().filter { $0.bundleId == bundleId }
}

public func xauXatContactInvitePermissions(connectionId: Int64) -> XauXatContactInvitePermissions {
    xauXatObserveContactInvitePolicy(connectionId: connectionId)?.permissions ?? .init()
}

public func xauXatContactInvitePermissions(_ contact: Contact) -> XauXatContactInvitePermissions {
    guard let connectionId = contact.activeConn?.connId else { return .init() }
    return xauXatContactInvitePermissions(connectionId: connectionId)
}

public enum XauXatOneTimeGroupInviteState: String, Codable, Hashable {
    case active
    case processing
    case consumed
    case failed
    case revoked
    case expired
}

public struct XauXatOneTimeGroupInvite: Codable, Hashable, Identifiable {
    public let connectionId: Int64
    public let groupId: Int64
    public let groupDisplayName: String
    public let memberRole: GroupMemberRole
    public var shareLink: String?
    public var accessCode: String?
    public let accessCodeIsOneTime: Bool?
    public let createdAt: Date
    public let expiresAt: Date?
    public var state: XauXatOneTimeGroupInviteState
    public var contactId: Int64?
    public var consumedAt: Date?
    public var groupInvitationSentAt: Date?
    public var coreAccessDeletedAt: Date?
    public var lastError: String?

    public var id: Int64 { connectionId }
    public var isProtected: Bool { accessCode != nil || accessCodeIsOneTime == true }
    public var usesOneTimeAccessCode: Bool { accessCodeIsOneTime == true }

    public init(
        connectionId: Int64,
        groupId: Int64,
        groupDisplayName: String,
        memberRole: GroupMemberRole,
        shareLink: String,
        accessCode: String?,
        accessCodeIsOneTime: Bool = false,
        createdAt: Date = .now,
        expiresAt: Date? = nil,
        state: XauXatOneTimeGroupInviteState = .active,
        contactId: Int64? = nil,
        consumedAt: Date? = nil,
        groupInvitationSentAt: Date? = nil,
        coreAccessDeletedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.connectionId = connectionId
        self.groupId = groupId
        self.groupDisplayName = groupDisplayName
        self.memberRole = memberRole
        self.shareLink = shareLink
        self.accessCode = accessCode
        self.accessCodeIsOneTime = accessCodeIsOneTime
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.state = state
        self.contactId = contactId
        self.consumedAt = consumedAt
        self.groupInvitationSentAt = groupInvitationSentAt
        self.coreAccessDeletedAt = coreAccessDeletedAt
        self.lastError = lastError
    }
}

public extension Notification.Name {
    static let xauXatOneTimeGroupInvitesChanged = Notification.Name("xauXatOneTimeGroupInvitesChanged")
}

private var kcOneTimeGroupInvites: KeyChainItem {
    xauXatStorageScope() == .decoy ? kcDecoyOneTimeGroupInvites : kcPrimaryOneTimeGroupInvites
}

private func xauXatReadOneTimeGroupInvites() -> [Int64: XauXatOneTimeGroupInvite] {
    guard let value = kcOneTimeGroupInvites.get(),
          let data = value.data(using: .utf8),
          let invites = try? JSONDecoder().decode([String: XauXatOneTimeGroupInvite].self, from: data) else { return [:] }
    return Dictionary(uniqueKeysWithValues: invites.compactMap { key, value in
        Int64(key).map { ($0, value) }
    })
}

@discardableResult
private func xauXatWriteOneTimeGroupInvites(_ invites: [Int64: XauXatOneTimeGroupInvite]) -> Bool {
    let saved: Bool
    if invites.isEmpty {
        saved = kcOneTimeGroupInvites.remove()
    } else {
        let encoded = Dictionary(uniqueKeysWithValues: invites.map { (String($0.key), $0.value) })
        guard let data = try? JSONEncoder().encode(encoded),
              let value = String(data: data, encoding: .utf8) else { return false }
        saved = kcOneTimeGroupInvites.set(value)
    }
    if saved {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .xauXatOneTimeGroupInvitesChanged, object: nil)
        }
    }
    return saved
}

public func xauXatOneTimeGroupInvites(groupId: Int64? = nil, at now: Date = .now) -> [XauXatOneTimeGroupInvite] {
    xauXatOneTimeGroupInvitesLock.lock()
    defer { xauXatOneTimeGroupInvitesLock.unlock() }
    var invites = xauXatReadOneTimeGroupInvites()
    var changed = false
    for (connectionId, var invite) in invites {
        if invite.state == .active, let expiresAt = invite.expiresAt, expiresAt <= now {
            invite.state = .expired
            invite.shareLink = nil
            if invite.usesOneTimeAccessCode { invite.accessCode = nil }
            invites[connectionId] = invite
            changed = true
        } else if invite.state == .processing,
                  let consumedAt = invite.consumedAt,
                  now.timeIntervalSince(consumedAt) >= 120 {
            invite.state = .failed
            invite.lastError = NSLocalizedString(
                "Group invitation delivery was interrupted. Retry is safe and does not reactivate the public link.",
                comment: "one-time group invite interrupted delivery"
            )
            invites[connectionId] = invite
            changed = true
        }
    }
    if changed { _ = xauXatWriteOneTimeGroupInvites(invites) }
    return invites.values
        .filter { groupId == nil || $0.groupId == groupId }
        .sorted { $0.createdAt > $1.createdAt }
}

public func xauXatOneTimeGroupInvite(connectionId: Int64) -> XauXatOneTimeGroupInvite? {
    xauXatOneTimeGroupInvites(groupId: nil).first { $0.connectionId == connectionId }
}

@discardableResult
public func xauXatSaveOneTimeGroupInvite(_ invite: XauXatOneTimeGroupInvite) -> Bool {
    xauXatOneTimeGroupInvitesLock.lock()
    defer { xauXatOneTimeGroupInvitesLock.unlock() }
    var invites = xauXatReadOneTimeGroupInvites()
    invites[invite.connectionId] = invite
    return xauXatWriteOneTimeGroupInvites(invites)
}

public func xauXatClaimOneTimeGroupInvite(connectionId: Int64, contactId: Int64, at now: Date = .now) -> XauXatOneTimeGroupInvite? {
    xauXatOneTimeGroupInvitesLock.lock()
    defer { xauXatOneTimeGroupInvitesLock.unlock() }
    var invites = xauXatReadOneTimeGroupInvites()
    guard var invite = invites[connectionId] else { return nil }
    if invite.state == .active, let expiresAt = invite.expiresAt, expiresAt <= now {
        invite.state = .expired
        invites[connectionId] = invite
        _ = xauXatWriteOneTimeGroupInvites(invites)
        return nil
    }
    guard invite.state == .active || (invite.state == .failed && invite.contactId == contactId) else { return nil }
    invite.state = .processing
    invite.contactId = contactId
    invite.consumedAt = invite.consumedAt ?? now
    invite.lastError = nil
    invite.shareLink = nil
    if invite.usesOneTimeAccessCode { invite.accessCode = nil }
    invites[connectionId] = invite
    guard xauXatWriteOneTimeGroupInvites(invites) else { return nil }
    return invite
}

@discardableResult
public func xauXatCompleteOneTimeGroupInvite(connectionId: Int64, at now: Date = .now) -> Bool {
    xauXatOneTimeGroupInvitesLock.lock()
    defer { xauXatOneTimeGroupInvitesLock.unlock() }
    var invites = xauXatReadOneTimeGroupInvites()
    guard var invite = invites[connectionId], invite.state == .processing else { return false }
    invite.state = .consumed
    invite.groupInvitationSentAt = now
    invite.lastError = nil
    invites[connectionId] = invite
    return xauXatWriteOneTimeGroupInvites(invites)
}

@discardableResult
public func xauXatFailOneTimeGroupInvite(connectionId: Int64, error: String) -> Bool {
    xauXatOneTimeGroupInvitesLock.lock()
    defer { xauXatOneTimeGroupInvitesLock.unlock() }
    var invites = xauXatReadOneTimeGroupInvites()
    guard var invite = invites[connectionId], invite.state == .processing else { return false }
    invite.state = .failed
    invite.lastError = error
    invites[connectionId] = invite
    return xauXatWriteOneTimeGroupInvites(invites)
}

@discardableResult
public func xauXatRevokeOneTimeGroupInvite(connectionId: Int64) -> Bool {
    xauXatOneTimeGroupInvitesLock.lock()
    defer { xauXatOneTimeGroupInvitesLock.unlock() }
    var invites = xauXatReadOneTimeGroupInvites()
    guard var invite = invites[connectionId], invite.state == .active || invite.state == .failed else { return false }
    invite.state = .revoked
    invite.coreAccessDeletedAt = .now
    invite.shareLink = nil
    if invite.usesOneTimeAccessCode { invite.accessCode = nil }
    invites[connectionId] = invite
    return xauXatWriteOneTimeGroupInvites(invites)
}

@discardableResult
public func xauXatMarkOneTimeGroupInviteCoreDeleted(connectionId: Int64, at now: Date = .now) -> Bool {
    xauXatOneTimeGroupInvitesLock.lock()
    defer { xauXatOneTimeGroupInvitesLock.unlock() }
    var invites = xauXatReadOneTimeGroupInvites()
    guard var invite = invites[connectionId] else { return false }
    invite.coreAccessDeletedAt = now
    invites[connectionId] = invite
    return xauXatWriteOneTimeGroupInvites(invites)
}

@discardableResult
public func xauXatRemoveOneTimeGroupInvites(_ scope: XauXatStorageScope) -> Bool {
    xauXatOneTimeGroupInvitesLock.lock()
    defer { xauXatOneTimeGroupInvitesLock.unlock() }
    switch scope {
    case .primary: return kcPrimaryOneTimeGroupInvites.remove()
    case .decoy: return kcDecoyOneTimeGroupInvites.remove()
    }
}

public struct XauXatGroupAccessPolicy: Codable, Hashable, Sendable {
    public let groupId: Int64
    public let accessCode: String
    public let protectedLink: String
    public let rawLinkFingerprint: String
    public let createdAt: Date
    public let expiresAt: Date?

    public init(groupId: Int64, accessCode: String, protectedLink: String, rawLinkFingerprint: String, createdAt: Date, expiresAt: Date? = nil) {
        self.groupId = groupId
        self.accessCode = accessCode
        self.protectedLink = protectedLink
        self.rawLinkFingerprint = rawLinkFingerprint
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date = .now) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }
}

public enum XauXatGroupAccessUnlockResult: Sendable {
    case notProtected
    case unlocked(link: String)
    case incorrectCode(retryAfter: Int)
    case rateLimited(retryAfter: Int)
    case expired
    case invalid
}

private struct XauXatGroupAccessEnvelope: Codable {
    let version: Int
    let kdf: String
    let iterations: Int
    let salt: Data
    let sealedLink: Data
}

private struct XauXatGroupAccessPayload: Codable {
    let link: String
    let expiresAt: Int64?
}

private struct XauXatGroupAccessAttemptState: Codable {
    var failures: Int
    var blockedUntil: Date
}

private let XAUXAT_GROUP_ACCESS_VERSION = 2
private let XAUXAT_GROUP_ACCESS_KDF = "pbkdf2-sha256"
private let XAUXAT_GROUP_ACCESS_ITERATIONS = 310_000
private let XAUXAT_GROUP_ACCESS_SALT_BYTES = 16
private let XAUXAT_GROUP_ACCESS_KEY_BYTES = 32
private let XAUXAT_GROUP_ACCESS_QUERY_ITEM = "xau_group"
private let XAUXAT_GROUP_ACCESS_HOST = "xauxat.app"
private let XAUXAT_GROUP_ACCESS_PATH = "/group-access"
private let XAUXAT_GROUP_ACCESS_CODE_ALPHABET = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

private var kcGroupAccessPolicies: KeyChainItem {
    xauXatStorageScope() == .decoy ? kcDecoyGroupAccessPolicies : kcPrimaryGroupAccessPolicies
}

private func xauXatGroupAccessRawLinkFingerprint(_ link: String) -> String {
    xauXatBase64URL(Data(SHA256.hash(data: Data(link.utf8))))
}

private func xauXatGroupAccessAttemptKey(_ link: String) -> String {
    let scope = xauXatStorageScope() == .decoy ? "localProfile" : "primary"
    let fingerprint = xauXatBase64URL(Data(SHA256.hash(data: Data(link.utf8))))
    return "\(GROUP_ACCESS_ATTEMPTS_PREFIX).\(scope).\(fingerprint)"
}

private func xauXatGroupAccessExpiredKey(_ link: String) -> String {
    let scope = xauXatStorageScope() == .decoy ? "localProfile" : "primary"
    let fingerprint = xauXatBase64URL(Data(SHA256.hash(data: Data(link.utf8))))
    return "\(GROUP_ACCESS_EXPIRED_PREFIX).\(scope).\(fingerprint)"
}

private func xauXatReadGroupAccessPolicies() -> [Int64: XauXatGroupAccessPolicy] {
    guard let value = kcGroupAccessPolicies.get(),
          let data = value.data(using: .utf8),
          let policies = try? JSONDecoder().decode([String: XauXatGroupAccessPolicy].self, from: data) else { return [:] }
    return Dictionary(uniqueKeysWithValues: policies.compactMap { key, value in
        Int64(key).map { ($0, value) }
    })
}

@discardableResult
private func xauXatWriteGroupAccessPolicies(_ policies: [Int64: XauXatGroupAccessPolicy]) -> Bool {
    guard !policies.isEmpty else { return kcGroupAccessPolicies.remove() }
    let encoded = Dictionary(uniqueKeysWithValues: policies.map { (String($0.key), $0.value) })
    guard let data = try? JSONEncoder().encode(encoded),
          let value = String(data: data, encoding: .utf8) else { return false }
    return kcGroupAccessPolicies.set(value)
}

public func xauXatGroupAccessPolicy(groupId: Int64) -> XauXatGroupAccessPolicy? {
    xauXatGroupAccessPoliciesLock.lock()
    defer { xauXatGroupAccessPoliciesLock.unlock() }
    return xauXatReadGroupAccessPolicies()[groupId]
}

public func xauXatGroupAccessPolicies() -> [XauXatGroupAccessPolicy] {
    xauXatGroupAccessPoliciesLock.lock()
    defer { xauXatGroupAccessPoliciesLock.unlock() }
    return Array(xauXatReadGroupAccessPolicies().values)
}

@discardableResult
public func xauXatSaveGroupAccessPolicy(_ policy: XauXatGroupAccessPolicy) -> Bool {
    xauXatGroupAccessPoliciesLock.lock()
    defer { xauXatGroupAccessPoliciesLock.unlock() }
    var policies = xauXatReadGroupAccessPolicies()
    policies[policy.groupId] = policy
    return xauXatWriteGroupAccessPolicies(policies)
}

@discardableResult
public func xauXatRemoveGroupAccessPolicy(groupId: Int64) -> Bool {
    xauXatGroupAccessPoliciesLock.lock()
    defer { xauXatGroupAccessPoliciesLock.unlock() }
    var policies = xauXatReadGroupAccessPolicies()
    policies.removeValue(forKey: groupId)
    return xauXatWriteGroupAccessPolicies(policies)
}

@discardableResult
public func xauXatRemoveGroupAccessPolicies(_ scope: XauXatStorageScope) -> Bool {
    xauXatGroupAccessPoliciesLock.lock()
    defer { xauXatGroupAccessPoliciesLock.unlock() }
    switch scope {
    case .primary: return kcPrimaryGroupAccessPolicies.remove()
    case .decoy: return kcDecoyGroupAccessPolicies.remove()
    }
}

public func xauXatGenerateGroupAccessCode() -> String? {
    var characters: [Character] = []
    while characters.count < 12 {
        var byte: UInt8 = 0
        guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else { return nil }
        // Rejection sampling avoids modulo bias for the 32-character alphabet.
        guard Int(byte) < 224 else { continue }
        characters.append(XAUXAT_GROUP_ACCESS_CODE_ALPHABET[Int(byte) % XAUXAT_GROUP_ACCESS_CODE_ALPHABET.count])
    }
    let raw = String(characters)
    return stride(from: 0, to: raw.count, by: 4).map { offset in
        let start = raw.index(raw.startIndex, offsetBy: offset)
        let end = raw.index(start, offsetBy: min(4, raw.distance(from: start, to: raw.endIndex)))
        return String(raw[start..<end])
    }.joined(separator: "-")
}

public func xauXatCreateGroupAccessPolicy(groupId: Int64, rawLink: String, expiresAt: Date? = nil) -> XauXatGroupAccessPolicy? {
    guard let code = xauXatGenerateGroupAccessCode(),
          let protectedLink = xauXatProtectedGroupInviteLink(rawLink: rawLink, accessCode: code, expiresAt: expiresAt) else { return nil }
    return XauXatGroupAccessPolicy(
        groupId: groupId,
        accessCode: code,
        protectedLink: protectedLink,
        rawLinkFingerprint: xauXatGroupAccessRawLinkFingerprint(rawLink),
        createdAt: .now,
        expiresAt: expiresAt
    )
}

public func xauXatRefreshGroupAccessPolicy(_ policy: XauXatGroupAccessPolicy, rawLink: String) -> XauXatGroupAccessPolicy? {
    guard let protectedLink = xauXatProtectedGroupInviteLink(rawLink: rawLink, accessCode: policy.accessCode, expiresAt: policy.expiresAt) else { return nil }
    return XauXatGroupAccessPolicy(
        groupId: policy.groupId,
        accessCode: policy.accessCode,
        protectedLink: protectedLink,
        rawLinkFingerprint: xauXatGroupAccessRawLinkFingerprint(rawLink),
        createdAt: policy.createdAt,
        expiresAt: policy.expiresAt
    )
}

public func xauXatGroupAccessPolicyMatches(_ policy: XauXatGroupAccessPolicy, rawLink: String) -> Bool {
    policy.rawLinkFingerprint == xauXatGroupAccessRawLinkFingerprint(rawLink)
}

public func xauXatIsProtectedGroupInviteLink(_ value: String) -> Bool {
    guard let components = URLComponents(string: value) else { return false }
    return components.host == XAUXAT_GROUP_ACCESS_HOST
        && components.path == XAUXAT_GROUP_ACCESS_PATH
        && components.queryItems?.contains(where: { $0.name == XAUXAT_GROUP_ACCESS_QUERY_ITEM }) == true
}

public func xauXatProtectedGroupInviteLink(rawLink: String, accessCode: String, expiresAt: Date? = nil) -> String? {
    guard !rawLink.isEmpty,
          let normalizedCode = xauXatNormalizedGroupAccessCode(accessCode),
          let salt = xauXatRandomData(count: XAUXAT_GROUP_ACCESS_SALT_BYTES),
          let key = xauXatGroupAccessKey(code: normalizedCode, salt: salt, iterations: XAUXAT_GROUP_ACCESS_ITERATIONS) else { return nil }
    let header = xauXatGroupAccessHeader(version: XAUXAT_GROUP_ACCESS_VERSION)
    let payload = XauXatGroupAccessPayload(
        link: rawLink,
        expiresAt: expiresAt.map { Int64($0.timeIntervalSince1970.rounded(.down)) }
    )
    guard let payloadData = try? JSONEncoder().encode(payload),
          let box = try? ChaChaPoly.seal(payloadData, using: key, authenticating: header) else { return nil }
    let envelope = XauXatGroupAccessEnvelope(
        version: XAUXAT_GROUP_ACCESS_VERSION,
        kdf: XAUXAT_GROUP_ACCESS_KDF,
        iterations: XAUXAT_GROUP_ACCESS_ITERATIONS,
        salt: salt,
        sealedLink: box.combined
    )
    guard let data = try? JSONEncoder().encode(envelope) else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = XAUXAT_GROUP_ACCESS_HOST
    components.path = XAUXAT_GROUP_ACCESS_PATH
    components.queryItems = [URLQueryItem(name: XAUXAT_GROUP_ACCESS_QUERY_ITEM, value: xauXatBase64URL(data))]
    return components.string
}

public func xauXatUnlockProtectedGroupInvite(
    _ value: String,
    accessCode: String,
    at now: Date = .now
) -> XauXatGroupAccessUnlockResult {
    guard xauXatIsProtectedGroupInviteLink(value) else { return .notProtected }
    let attemptItem = KeyChainItem(forKey: xauXatGroupAccessAttemptKey(value))
    let expiredItem = KeyChainItem(forKey: xauXatGroupAccessExpiredKey(value))
    if expiredItem.get() != nil { return .expired }
    if let stored = attemptItem.get(),
       let data = stored.data(using: .utf8),
       let state = try? JSONDecoder().decode(XauXatGroupAccessAttemptState.self, from: data),
       state.blockedUntil > now {
        return .rateLimited(retryAfter: max(1, Int(ceil(state.blockedUntil.timeIntervalSince(now)))))
    }
    guard let components = URLComponents(string: value),
          let encoded = components.queryItems?.first(where: { $0.name == XAUXAT_GROUP_ACCESS_QUERY_ITEM })?.value,
          let data = xauXatBase64URLData(encoded),
          let envelope = try? JSONDecoder().decode(XauXatGroupAccessEnvelope.self, from: data),
          (1...XAUXAT_GROUP_ACCESS_VERSION).contains(envelope.version),
          envelope.kdf == XAUXAT_GROUP_ACCESS_KDF,
          envelope.iterations == XAUXAT_GROUP_ACCESS_ITERATIONS,
          envelope.salt.count == XAUXAT_GROUP_ACCESS_SALT_BYTES,
          let box = try? ChaChaPoly.SealedBox(combined: envelope.sealedLink) else { return .invalid }
    guard let normalizedCode = xauXatNormalizedGroupAccessCode(accessCode),
          let key = xauXatGroupAccessKey(code: normalizedCode, salt: envelope.salt, iterations: envelope.iterations) else {
        return xauXatRecordGroupAccessFailure(attemptItem: attemptItem, now: now)
    }
    do {
        let cleartext = try ChaChaPoly.open(box, using: key, authenticating: xauXatGroupAccessHeader(version: envelope.version))
        let link: String
        if envelope.version == 1 {
            guard let legacyLink = String(data: cleartext, encoding: .utf8), !legacyLink.isEmpty else { return .invalid }
            link = legacyLink
        } else {
            guard let payload = try? JSONDecoder().decode(XauXatGroupAccessPayload.self, from: cleartext),
                  !payload.link.isEmpty else { return .invalid }
            if let expiresAt = payload.expiresAt,
               now >= Date(timeIntervalSince1970: TimeInterval(expiresAt)) {
                _ = attemptItem.remove()
                _ = expiredItem.set("expired")
                return .expired
            }
            link = payload.link
        }
        _ = attemptItem.remove()
        return .unlocked(link: link)
    } catch {
        return xauXatRecordGroupAccessFailure(attemptItem: attemptItem, now: now)
    }
}

private func xauXatRecordGroupAccessFailure(attemptItem: KeyChainItem, now: Date) -> XauXatGroupAccessUnlockResult {
    let previous: XauXatGroupAccessAttemptState? = attemptItem.get()
        .flatMap { $0.data(using: .utf8) }
        .flatMap { try? JSONDecoder().decode(XauXatGroupAccessAttemptState.self, from: $0) }
    let failures = (previous?.failures ?? 0) + 1
    let delay = min(60, 1 << min(max(0, failures - 1), 6))
    let state = XauXatGroupAccessAttemptState(failures: failures, blockedUntil: now.addingTimeInterval(TimeInterval(delay)))
    if let stateData = try? JSONEncoder().encode(state), let stateValue = String(data: stateData, encoding: .utf8) {
        _ = attemptItem.set(stateValue)
    }
    return .incorrectCode(retryAfter: delay)
}

private func xauXatNormalizedGroupAccessCode(_ code: String) -> String? {
    let normalized = code.uppercased().filter { $0.isLetter || $0.isNumber }
    return normalized.count == 12 ? normalized : nil
}

private func xauXatGroupAccessHeader(version: Int) -> Data {
    Data("xauxat.group-access|v\(version)|pbkdf2-sha256|310000|chacha20-poly1305".utf8)
}

private func xauXatRandomData(count: Int) -> Data? {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { bytes in
        SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
    }
    return status == errSecSuccess ? data : nil
}

private func xauXatGroupAccessKey(code: String, salt: Data, iterations: Int) -> SymmetricKey? {
    let password = Array(code.utf8)
    var key = [UInt8](repeating: 0, count: XAUXAT_GROUP_ACCESS_KEY_BYTES)
    let result = password.withUnsafeBytes { passwordBytes in
        salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                passwordBytes.count,
                saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &key,
                key.count
            )
        }
    }
    return result == kCCSuccess ? SymmetricKey(data: key) : nil
}

public struct KeyChainItem {
    var forKey: String

    public func get() -> String? {
        getItemString(forKey: forKey)
    }

    public func set(_ value: String) -> Bool {
        setItemString(value, forKey: forKey)
    }

    public func remove() -> Bool {
        deleteItem(forKey: forKey)
    }
}

private func xauXatCodeLockedAttemptsKey(_ contentID: String) -> String {
    let scope = xauXatStorageScope() == .decoy ? "localProfile" : "primary"
    return "\(CODE_LOCKED_ATTEMPTS_PREFIX).\(scope).\(contentID)"
}

public func xauXatCodeLockedAttemptCount(_ contentID: String) -> Int {
    Int(KeyChainItem(forKey: xauXatCodeLockedAttemptsKey(contentID)).get() ?? "") ?? 0
}

public func xauXatCodeLockedContentDestroyed(_ contentID: String) -> Bool {
    KeyChainItem(forKey: xauXatCodeLockedAttemptsKey(contentID)).get() == "destroyed"
}

@discardableResult
public func xauXatSetCodeLockedAttemptCount(_ count: Int, contentID: String) -> Bool {
    let item = KeyChainItem(forKey: xauXatCodeLockedAttemptsKey(contentID))
    return count > 0 ? item.set(String(count)) : item.remove()
}

@discardableResult
public func xauXatMarkCodeLockedContentDestroyed(_ contentID: String) -> Bool {
    KeyChainItem(forKey: xauXatCodeLockedAttemptsKey(contentID)).set("destroyed")
}

func randomDatabasePassword() -> String {
    var keyData = Data(count: 32)
    let status = keyData.withUnsafeMutableBytes {
        SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
    }
    if status == errSecSuccess {
        return keyData.base64EncodedString()
    } else {
        logger.error("randomDatabasePassword: error \(status)")
        return ""
    }
}

private func getItemData(forKey key: String) -> Data? {
    var query = baseItemQuery(forKey: key)
    query[kSecMatchLimit] = kSecMatchLimitOne
    query[kSecReturnData] = true as AnyObject?

    var dataRef: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &dataRef)
    if status != errSecSuccess && status != errSecItemNotFound {
        logger.error("getItemData: error getting data for key '\(key)', error: \(status)")
    }
    return dataRef as? Data
}

private func getItemString(forKey key: String) -> String? {
    if let data = getItemData(forKey: key) {
        return NSString(data: data, encoding: String.Encoding.utf8.rawValue) as? String
    }
    return nil
}

private func setItemData(_ data: Data, forKey key: String) -> Bool {
    var query = baseItemQuery(forKey: key)
    var update = [NSString : AnyObject]()
    update[kSecValueData] = data as AnyObject?
    update[kSecAttrAccessible] = ACCESS_POLICY
    var status: OSStatus
    if getItemData(forKey: key) == nil {
        for (key, value) in update { query[key] = value }
        status = SecItemAdd(query as CFDictionary, nil)
    } else {
        status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    }
    if status != errSecSuccess {
        logger.error("setItemData: error setting data for key '\(key)', error: \(status)")
        return false
    }
    return true
}

private func setItemString(_ s: String, forKey key: String) -> Bool {
    if let data = s.data(using: .utf8) {
        return setItemData(data, forKey: key)
    }
    return false
}

private func deleteItem(forKey key: String) -> Bool {
    let query = baseItemQuery(forKey: key)
    if getItemData(forKey: key) != nil {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess {
            logger.error("deleteItem: error deleting data for key '\(key)', error: \(status)")
            return false
        }
    }
    return true
}

private func baseItemQuery(forKey key: String) -> [NSString : AnyObject] {
    var query = [NSString : AnyObject]()
    query[kSecClass] = kSecClassGenericPassword
    query[kSecAttrAccount] = key as AnyObject?
    #if TARGET_OS_IOS && !TARGET_OS_SIMULATOR
        query[kSecAttrAccessGroup] = ACCESS_GROUP
    #endif
    return query
}
