//
//  KeyChain.swift
//  SimpleXChat
//
//  Created by Evgeny on 04/09/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import Foundation
import Security

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
