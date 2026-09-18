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
private let xauXatContactInvitePoliciesLock = NSLock()
private let xauXatExpiredContactInviteEnvelopesLock = NSLock()
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

    public init(
        connectionId: Int64,
        createdAt: Date,
        expiresAt: Date? = nil,
        permissions: XauXatContactInvitePermissions? = nil
    ) {
        self.connectionId = connectionId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.maxObservedAt = createdAt
        self.state = .active
        self.permissions = permissions
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
    case valid(link: String, expiresAt: Date?, permissions: XauXatContactInvitePermissions)
    case expired(link: String, expiresAt: Date)
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
    link: String,
    expiresAt: Int64?,
    permissions: XauXatContactInvitePermissions,
    version: Int
) -> Data {
    if version == 1, let expiresAt {
        return Data("xauxat-contact-invite-v1\n\(expiresAt)\n\(link)".utf8)
    }
    return Data(
        "xauxat-contact-invite-v2\n\(expiresAt.map { String($0) } ?? "never")\n\(permissions.messages ? 1 : 0)\n\(permissions.calls ? 1 : 0)\n\(link)".utf8
    )
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
    guard var components = URLComponents(string: link) else { return nil }
    // A fresh signing key per rendered invite avoids introducing a reusable,
    // globally correlatable identifier across otherwise anonymous links.
    let key = P256.Signing.PrivateKey()
    let expiry = expiresAt.map { Int64($0.timeIntervalSince1970) }
    guard let signature = try? key.signature(for: xauXatContactInviteCanonicalData(
        link: link,
        expiresAt: expiry,
        permissions: permissions,
        version: 2
    )) else { return nil }
    let envelope = XauXatContactInviteEnvelope(
        version: 2,
        link: link,
        expiresAt: expiry,
        publicKey: xauXatBase64URL(key.publicKey.x963Representation),
        signature: xauXatBase64URL(signature.rawRepresentation),
        messages: permissions.messages,
        calls: permissions.calls
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
          envelope.version == 1 || envelope.version == 2,
          let publicKeyData = xauXatBase64URLData(envelope.publicKey),
          let signatureData = xauXatBase64URLData(envelope.signature),
          let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData),
          let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
          publicKey.isValidSignature(
              signature,
              for: xauXatContactInviteCanonicalData(
                  link: envelope.link,
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
    guard let expiry = envelope.expiresAt else {
        return .valid(link: envelope.link, expiresAt: nil, permissions: permissions)
    }
    let expiresAt = Date(timeIntervalSince1970: TimeInterval(expiry))
    let fingerprint = xauXatContactInviteEnvelopeFingerprint(encodedEnvelope)
    if observedAt >= expiresAt || xauXatExpiredContactInviteEnvelopeFingerprints().contains(fingerprint) {
        xauXatExpiredContactInviteEnvelopesLock.lock()
        xauXatMarkContactInviteEnvelopeExpired(encodedEnvelope)
        xauXatExpiredContactInviteEnvelopesLock.unlock()
        return .expired(link: envelope.link, expiresAt: expiresAt)
    }
    return .valid(link: envelope.link, expiresAt: expiresAt, permissions: permissions)
}

public func xauXatContactInvitePermissions(connectionId: Int64) -> XauXatContactInvitePermissions {
    xauXatObserveContactInvitePolicy(connectionId: connectionId)?.permissions ?? .init()
}

public func xauXatContactInvitePermissions(_ contact: Contact) -> XauXatContactInvitePermissions {
    guard let connectionId = contact.activeConn?.connId else { return .init() }
    return xauXatContactInvitePermissions(connectionId: connectionId)
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
