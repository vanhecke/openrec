import Foundation
import Security
import XCTest
@testable import OpenRecApp

final class KeychainStoreTests: XCTestCase {
    private let openAIAccount = MeetingMemoryProvider.openAIKeychainAccount
    private let grokAccount = MeetingMemoryProvider.grokKeychainAccount
    private let assemblyAccount = "assemblyai-api-key"

    private var keychainService: String {
#if DEBUG
        "app.openrec.credentials.dev"
#else
        "app.openrec.credentials"
#endif
    }

    override func tearDown() {
        KeychainStore.resetForTesting()
        super.tearDown()
    }

    func testAuthFailedInteractionNotAllowedAndUserCanceledReadAsEmpty() {
        let payload = Data("stored-value".utf8)
        for status in inaccessibleStatuses {
            XCTAssertEqual(
                KeychainStore.string(forReadStatus: status, result: payload),
                "",
                "status \(status) must not surface the stored bytes"
            )
            XCTAssertEqual(KeychainStore.string(forReadStatus: status, result: nil), "")
        }
        XCTAssertEqual(KeychainStore.string(forReadStatus: errSecItemNotFound, result: payload), "")
        XCTAssertEqual(
            KeychainStore.string(forReadStatus: errSecSuccess, result: payload),
            "stored-value"
        )
    }

    func testInaccessibleReadsFailClosedAndDoNotRetry() {
        for status in inaccessibleStatuses {
            KeychainStore.resetForTesting()
            let keychain = MemoryKeychain()
            keychain.remember(openAIAccount, value: "stored-value", readable: false)
            keychain.inaccessibleStatus = status
            KeychainStore.useOperationsForTesting(keychain.operations())

            XCTAssertEqual(KeychainStore.string(for: openAIAccount), "")
            XCTAssertEqual(keychain.itemCalls.map(\.name), ["copy"])
            XCTAssertFalse(keychain.itemCalls[0].interactionAllowed)
            assertFailsClosed(keychain.copyQueries[0], account: openAIAccount, returnsData: true)
            XCTAssertEqual(keychain.interactionLog, [false, true])
            XCTAssertTrue(keychain.interactionAllowed)

            let calls = keychain.itemCalls.count
            let interactions = keychain.interactionLog.count
            XCTAssertEqual(KeychainStore.string(for: openAIAccount), "")
            XCTAssertEqual(keychain.itemCalls.count, calls)
            XCTAssertEqual(keychain.interactionLog.count, interactions)
        }
    }

    func testMissingReadsAreCachedSoMenuRefreshDoesNotRequery() {
        let keychain = MemoryKeychain()
        KeychainStore.useOperationsForTesting(keychain.operations())

        XCTAssertEqual(KeychainStore.string(for: openAIAccount), "")
        XCTAssertEqual(KeychainStore.string(for: openAIAccount), "")

        XCTAssertEqual(keychain.itemCalls.map(\.name), ["copy"])
        assertFailsClosed(keychain.copyQueries[0], account: openAIAccount, returnsData: true)
        XCTAssertEqual(keychain.interactionLog, [false, true])
    }

    func testSuccessfulSetIsVisibleToALaterRead() {
        let keychain = MemoryKeychain()
        KeychainStore.useOperationsForTesting(keychain.operations())

        KeychainStore.set("stored-value", for: openAIAccount)
        XCTAssertEqual(KeychainStore.string(for: openAIAccount), "stored-value")

        KeychainStore.discardCachedValuesForTesting()
        XCTAssertEqual(KeychainStore.string(for: openAIAccount), "stored-value")

        XCTAssertEqual(keychain.itemCalls.map(\.name), ["update", "add", "copy"])
        XCTAssertTrue(keychain.itemCalls.allSatisfy { !$0.interactionAllowed })
        XCTAssertEqual(keychain.storedValue(openAIAccount), "stored-value")
        assertFailsClosed(keychain.updateQueries[0], account: openAIAccount, returnsData: false)
        assertAdded("stored-value", account: openAIAccount, attributes: keychain.addAttributes[0])
        assertFailsClosed(keychain.copyQueries[0], account: openAIAccount, returnsData: true)
        XCTAssertTrue(keychain.interactionAllowed)
    }

    func testReadableUpdateDoesNotDeleteOrPrompt() {
        let keychain = MemoryKeychain()
        keychain.remember(openAIAccount, value: "stored-value", readable: true)
        KeychainStore.useOperationsForTesting(keychain.operations())

        KeychainStore.set("replacement-value", for: openAIAccount)

        XCTAssertEqual(keychain.itemCalls.map(\.name), ["update"])
        XCTAssertTrue(keychain.deleteQueries.isEmpty)
        XCTAssertFalse(keychain.itemCalls[0].interactionAllowed)
        XCTAssertEqual(KeychainStore.string(for: openAIAccount), "replacement-value")
        KeychainStore.discardCachedValuesForTesting()
        XCTAssertEqual(KeychainStore.string(for: openAIAccount), "replacement-value")
    }

    func testSavingReplacesAnInaccessibleItemWithoutUI() {
        for status in inaccessibleStatuses {
            KeychainStore.resetForTesting()
            let keychain = MemoryKeychain()
            keychain.remember(openAIAccount, value: "stored-value", readable: false)
            keychain.inaccessibleStatus = status
            KeychainStore.useOperationsForTesting(keychain.operations())

            XCTAssertEqual(KeychainStore.string(for: openAIAccount), "")
            KeychainStore.set("replacement-value", for: openAIAccount)

            XCTAssertEqual(
                keychain.itemCalls.map(\.name),
                ["copy", "update", "delete", "add"]
            )
            XCTAssertTrue(keychain.itemCalls.allSatisfy { !$0.interactionAllowed })
            assertFailsClosed(keychain.updateQueries[0], account: openAIAccount, returnsData: false)
            assertFailsClosed(keychain.deleteQueries[0], account: openAIAccount, returnsData: false)
            assertAdded("replacement-value", account: openAIAccount, attributes: keychain.addAttributes[0])
            XCTAssertEqual(KeychainStore.string(for: openAIAccount), "replacement-value")

            KeychainStore.discardCachedValuesForTesting()
            XCTAssertEqual(KeychainStore.string(for: openAIAccount), "replacement-value")
            XCTAssertTrue(keychain.interactionAllowed)
        }
    }

    func testUnrelatedUpdateFailureDoesNotReplaceOrHideTheStoredValue() {
        let keychain = MemoryKeychain()
        keychain.remember(openAIAccount, value: "stored-value", readable: true)
        keychain.forcedUpdateStatus = errSecParam
        KeychainStore.useOperationsForTesting(keychain.operations())

        XCTAssertEqual(KeychainStore.string(for: openAIAccount), "stored-value")
        KeychainStore.set("replacement-value", for: openAIAccount)

        XCTAssertTrue(keychain.deleteQueries.isEmpty)
        XCTAssertTrue(keychain.addAttributes.isEmpty)
        XCTAssertEqual(keychain.storedValue(openAIAccount), "stored-value")
        XCTAssertEqual(KeychainStore.string(for: openAIAccount), "stored-value")
    }

    func testClearingAValueDeletesWithoutUI() {
        let keychain = MemoryKeychain()
        keychain.remember(openAIAccount, value: "stored-value", readable: true)
        KeychainStore.useOperationsForTesting(keychain.operations())

        KeychainStore.set(" \n\t ", for: openAIAccount)

        XCTAssertEqual(keychain.itemCalls.map(\.name), ["delete"])
        XCTAssertFalse(keychain.itemCalls[0].interactionAllowed)
        assertFailsClosed(keychain.deleteQueries[0], account: openAIAccount, returnsData: false)
        XCTAssertNil(keychain.storedValue(openAIAccount))
        XCTAssertEqual(KeychainStore.string(for: openAIAccount), "")
        XCTAssertEqual(keychain.itemCalls.map(\.name), ["delete"])
    }

    func testOnboardingReadinessDoesNotRequeryKeychain() {
        let keychain = MemoryKeychain()
        let credentialAccounts = [assemblyAccount, grokAccount, openAIAccount]
        let storageAccounts = [
            OpenRecOnboarding.managedSessionKeychainAccount,
            OpenRecOnboarding.r2AccessKeyIDAccount,
            OpenRecOnboarding.r2SecretAccessKeyAccount,
        ]
        for account in credentialAccounts + storageAccounts {
            keychain.remember(account, value: "stored-value", readable: false)
        }
        KeychainStore.useOperationsForTesting(keychain.operations())

        _ = OpenRecOnboarding.currentReadiness()
        XCTAssertEqual(keychain.copyQueries.map { account(in: $0) }, credentialAccounts)
        for query in keychain.copyQueries {
            assertFailsClosed(query, account: account(in: query), returnsData: true)
        }
        XCTAssertTrue(keychain.itemCalls.allSatisfy { !$0.interactionAllowed })

        XCTAssertFalse(OpenRecOnboarding.isComplete)
        XCTAssertEqual(
            keychain.copyQueries.map { account(in: $0) },
            credentialAccounts + storageAccounts
        )
        for query in keychain.copyQueries {
            assertFailsClosed(query, account: account(in: query), returnsData: true)
        }
        XCTAssertTrue(keychain.itemCalls.allSatisfy { !$0.interactionAllowed })

        let copies = keychain.itemCalls.count
        XCTAssertFalse(OpenRecOnboarding.isComplete)
        XCTAssertEqual(keychain.itemCalls.count, copies)
    }

    func testDuplicateAddReplacesTheExistingItem() {
        let keychain = MemoryKeychain()
        keychain.remember(openAIAccount, value: "stored-value", readable: true)
        keychain.forcedUpdateStatus = errSecItemNotFound
        KeychainStore.useOperationsForTesting(keychain.operations())

        KeychainStore.set("replacement-value", for: openAIAccount)

        XCTAssertEqual(keychain.itemCalls.map(\.name), ["update", "add", "delete", "add"])
        XCTAssertTrue(keychain.itemCalls.allSatisfy { !$0.interactionAllowed })
        XCTAssertEqual(keychain.storedValue(openAIAccount), "replacement-value")
        XCTAssertEqual(KeychainStore.string(for: openAIAccount), "replacement-value")
    }

    func testReenteredReadDoesNotIssueAnotherQuery() {
        let reenteredAccount = self.assemblyAccount
        var copies = 0
        let operations = KeychainStore.Operations(
            copyMatching: { _ in
                copies += 1
                if copies == 1 {
                    _ = KeychainStore.string(for: reenteredAccount)
                }
                return (errSecInteractionNotAllowed, Data("stored-value".utf8))
            },
            update: { _, _ in errSecParam },
            delete: { _ in errSecParam },
            add: { _ in errSecParam },
            userInteractionAllowed: { true },
            setUserInteractionAllowed: { _ in }
        )
        KeychainStore.useOperationsForTesting(operations)

        XCTAssertEqual(KeychainStore.string(for: openAIAccount), "")
        XCTAssertEqual(copies, 1)

        XCTAssertEqual(KeychainStore.string(for: assemblyAccount), "")
        XCTAssertEqual(copies, 2)
    }

    private var inaccessibleStatuses: [OSStatus] {
        [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled]
    }

    private func assertFailsClosed(
        _ query: [String: Any],
        account: String,
        returnsData: Bool,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertEqual(self.account(in: query), account, file: file, line: line)
        XCTAssertEqual(query[kSecAttrService as String] as? String, keychainService, file: file, line: line)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String, file: file, line: line)
        XCTAssertEqual(
            query[kSecUseAuthenticationUI as String] as? String,
            kSecUseAuthenticationUIFail as String,
            file: file,
            line: line
        )
        if returnsData {
            XCTAssertEqual(query[kSecReturnData as String] as? Bool, true, file: file, line: line)
            XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String, file: file, line: line)
        } else {
            XCTAssertNil(query[kSecReturnData as String], file: file, line: line)
            XCTAssertNil(query[kSecMatchLimit as String], file: file, line: line)
        }
    }

    private func assertAdded(
        _ value: String,
        account: String,
        attributes: [String: Any],
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertEqual(self.account(in: attributes), account, file: file, line: line)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, keychainService, file: file, line: line)
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, Data(value.utf8), file: file, line: line)
        XCTAssertNil(attributes[kSecUseAuthenticationUI as String], file: file, line: line)
    }

    private func account(in query: [String: Any]) -> String {
        query[kSecAttrAccount as String] as? String ?? ""
    }
}

private final class MemoryKeychain {
    struct ItemCall {
        var name: String
        var interactionAllowed: Bool
    }

    var interactionAllowed = true
    var interactionLog: [Bool] = []
    var itemCalls: [ItemCall] = []
    var copyQueries: [[String: Any]] = []
    var updateQueries: [[String: Any]] = []
    var deleteQueries: [[String: Any]] = []
    var addAttributes: [[String: Any]] = []
    var inaccessibleStatus: OSStatus = errSecInteractionNotAllowed
    var forcedUpdateStatus: OSStatus?

    private var items: [String: Data] = [:]
    private var readable: Set<String> = []

    func remember(_ account: String, value: String, readable: Bool) {
        items[account] = Data(value.utf8)
        if readable {
            self.readable.insert(account)
        } else {
            self.readable.remove(account)
        }
    }

    func storedValue(_ account: String) -> String? {
        items[account].flatMap { String(data: $0, encoding: .utf8) }
    }

    func operations() -> KeychainStore.Operations {
        KeychainStore.Operations(
            copyMatching: { query in
                self.record("copy", query: query, into: \.copyQueries)
                let account = self.account(in: query)
                guard let data = self.items[account] else {
                    return (errSecItemNotFound, nil)
                }
                guard self.readable.contains(account) else {
                    return (self.inaccessibleStatus, data)
                }
                return (errSecSuccess, data)
            },
            update: { query, attributes in
                self.record("update", query: query, into: \.updateQueries)
                if let forcedUpdateStatus = self.forcedUpdateStatus {
                    return forcedUpdateStatus
                }
                let account = self.account(in: query)
                guard self.items[account] != nil else {
                    return errSecItemNotFound
                }
                guard self.readable.contains(account) else {
                    return self.inaccessibleStatus
                }
                guard let data = attributes[kSecValueData as String] as? Data else {
                    return errSecParam
                }
                self.items[account] = data
                return errSecSuccess
            },
            delete: { query in
                self.record("delete", query: query, into: \.deleteQueries)
                let account = self.account(in: query)
                guard self.items.removeValue(forKey: account) != nil else {
                    return errSecItemNotFound
                }
                self.readable.remove(account)
                return errSecSuccess
            },
            add: { attributes in
                self.record("add", query: attributes, into: \.addAttributes)
                let account = self.account(in: attributes)
                if self.items[account] != nil {
                    return errSecDuplicateItem
                }
                guard let data = attributes[kSecValueData as String] as? Data else {
                    return errSecParam
                }
                self.items[account] = data
                self.readable.insert(account)
                return errSecSuccess
            },
            userInteractionAllowed: { self.interactionAllowed },
            setUserInteractionAllowed: { allowed in
                self.interactionAllowed = allowed
                self.interactionLog.append(allowed)
            }
        )
    }

    private func record(
        _ name: String,
        query: [String: Any],
        into keyPath: ReferenceWritableKeyPath<MemoryKeychain, [[String: Any]]>
    ) {
        itemCalls.append(ItemCall(name: name, interactionAllowed: interactionAllowed))
        self[keyPath: keyPath].append(query)
    }

    private func account(in query: [String: Any]) -> String {
        query[kSecAttrAccount as String] as? String ?? ""
    }
}
