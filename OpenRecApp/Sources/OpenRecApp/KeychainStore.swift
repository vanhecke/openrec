import Foundation
import Security

enum KeychainStore {
    /// Security-framework calls. Tests install a stand-in so status mapping
    /// and query flags can be checked without a login-keychain dialog.
    struct Operations {
        var copyMatching: (_ query: [String: Any]) -> (OSStatus, Any?)
        var update: (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
        var delete: (_ query: [String: Any]) -> OSStatus
        var add: (_ attributes: [String: Any]) -> OSStatus
        var userInteractionAllowed: () -> Bool
        var setUserInteractionAllowed: (Bool) -> Void

        static let live = Operations(
            copyMatching: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result)
            },
            update: { query, attributes in
                SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            },
            delete: { query in
                SecItemDelete(query as CFDictionary)
            },
            add: { attributes in
                SecItemAdd(attributes as CFDictionary, nil)
            },
            userInteractionAllowed: KeychainStore.legacyUserInteractionAllowed,
            setUserInteractionAllowed: KeychainStore.setLegacyUserInteractionAllowed
        )
    }

    // Development builds use their own Keychain namespace so a dev app does
    // not block on credentials created by the production app.
    private static var service: String {
#if DEBUG
        "app.openrec.credentials.dev"
#else
        "app.openrec.credentials"
#endif
    }

    // Mutable state is only touched on the main thread. SecItem runs there
    // too: a background queue that then bounces to main deadlocks if
    // SecurityAgent tries to present UI, and a lock held across SecItem
    // deadlocks when that dialog's nested run loop reads the keychain again.
    private static var operations = Operations.live
    private static var cache: [String: String] = [:]
    private static var performing = false

    static func useOperationsForTesting(_ operations: Operations) {
        onMain {
            self.operations = operations
            cache.removeAll()
        }
    }

    static func resetForTesting() {
        useOperationsForTesting(.live)
    }

    static func discardCachedValuesForTesting() {
        onMain {
            cache.removeAll()
        }
    }

    static func string(for key: String) -> String {
        onMain {
            // A login-keychain dialog runs a nested run loop on this thread.
            // Another SecItem from layout or the status menu would stack a
            // second prompt, so a re-entrant read fails closed.
            if performing {
                return cache[key] ?? ""
            }
            if let cached = cache[key] {
                return cached
            }

            performing = true
            defer { performing = false }

            let (status, result) = withoutUserInteraction {
                operations.copyMatching(readQuery(for: key))
            }
            let value = string(forReadStatus: status, result: result)
            if shouldCache(status) {
                cache[key] = value
            }
            return value
        }
    }

    static func set(_ value: String, for key: String) {
        onMain {
            if performing {
                return
            }
            performing = true
            defer { performing = false }

            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                let status = withoutUserInteraction {
                    operations.delete(matchingQuery(for: key))
                }
                if status == errSecSuccess || status == errSecItemNotFound || isInaccessible(status) {
                    cache[key] = ""
                }
                return
            }

            let data = Data(value.utf8)
            guard withoutUserInteraction({ write(data, for: key) }) else { return }
            cache[key] = value
        }
    }

    /// `errSecAuthFailed`, `errSecInteractionNotAllowed`, and `errSecUserCanceled`
    /// are what macOS returns when the login-keychain ACL dialog was denied,
    /// canceled, or suppressed. They are empty reads, including when a result
    /// buffer is present.
    static func string(forReadStatus status: OSStatus, result: Any?) -> String {
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    private static func write(_ data: Data, for key: String) -> Bool {
        let status = operations.update(matchingQuery(for: key), [kSecValueData as String: data])
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return add(data, for: key)
        default:
            guard isInaccessible(status) else { return false }
            return replaceInaccessibleItem(data, for: key)
        }
    }

    private static func add(_ data: Data, for key: String) -> Bool {
        var item = baseQuery(for: key)
        item[kSecValueData as String] = data
        let status = operations.add(item)
        if status == errSecSuccess {
            return true
        }
        guard status == errSecDuplicateItem || isInaccessible(status) else {
            return false
        }
        return replaceInaccessibleItem(data, for: key)
    }

    /// Delete does not reveal the secret, so an item owned by an older ad-hoc
    /// signature can be removed without the login-keychain password. The
    /// replacement is owned by this binary and later reads of it do not prompt.
    private static func replaceInaccessibleItem(_ data: Data, for key: String) -> Bool {
        let deleted = operations.delete(matchingQuery(for: key))
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            return false
        }
        var item = baseQuery(for: key)
        item[kSecValueData as String] = data
        return operations.add(item) == errSecSuccess
    }

    private static func shouldCache(_ status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound || isInaccessible(status)
    }

    private static func isInaccessible(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed
            || status == errSecInteractionNotAllowed
            || status == errSecUserCanceled
    }

    private static func withoutUserInteraction<T>(_ body: () -> T) -> T {
        let previous = operations.userInteractionAllowed()
        operations.setUserInteractionAllowed(false)
        defer { operations.setUserInteractionAllowed(previous) }
        return body()
    }

    private static func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }

    private static func readQuery(for key: String) -> [String: Any] {
        var query = matchingQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    private static func matchingQuery(for key: String) -> [String: Any] {
        var query = baseQuery(for: key)
        // Honored by the data-protection keychain. The legacy login-keychain
        // ACL dialog ignores it and still presents SecurityAgent unless user
        // interaction is disabled around the SecItem call.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return query
    }

    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private static func legacyUserInteractionAllowed() -> Bool {
        var allowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess else {
            return true
        }
        return allowed.boolValue
    }

    private static func setLegacyUserInteractionAllowed(_ allowed: Bool) {
        // kSecUseAuthenticationUIFail does not suppress the login-keychain
        // dialog ("wants to use your confidential information stored in …").
        // This is the switch that makes that dialog fail closed.
        _ = SecKeychainSetUserInteractionAllowed(allowed)
    }
}
