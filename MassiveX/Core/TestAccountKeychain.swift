import Foundation
import LocalAuthentication
import Security

/// Only this interface may cross the secret storage boundary. Never store encoded keys in preferences.
@MainActor protocol TestAccountSecretStore {
    func saveNew(_ seed: Data) throws
    func load(context: LAContext?) throws -> Data?
    func delete() throws
}

enum TestAccountStorageError: Error, Equatable {
    case invalidSeed, accessControlUnavailable, keychain(OSStatus)
}

@MainActor protocol KeychainOperations {
    func add(_ query: [String: Any]) -> OSStatus
    func copy(_ query: [String: Any]) -> (OSStatus, Data?)
    func delete(_ query: [String: Any]) -> OSStatus
}

@MainActor struct SystemKeychainOperations: KeychainOperations {
    func add(_ query: [String: Any]) -> OSStatus { SecItemAdd(query as CFDictionary, nil) }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// Test accounts only. Requires an unlocked, passcode-protected device and user presence on reads.
/// This protects stored bytes; it is NOT Secure Enclave-backed Ed25519 signing.
@MainActor final class TestAccountKeychain: TestAccountSecretStore {
    private let operations: any KeychainOperations
    private let service: String
    private let account: String
    init(operations: any KeychainOperations = SystemKeychainOperations(), service: String = "com.massivex.mainnet.protected-wallet.v1", account: String = "wallet-account") {
        self.operations = operations
        self.service = service; self.account = account
    }
    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    func saveNew(_ seed: Data) throws {
        guard seed.count == 32 else { throw TestAccountStorageError.invalidSeed }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error) else {
            throw TestAccountStorageError.accessControlUnavailable
        }
        var query = identity
        query[kSecAttrAccessControl as String] = access
        query[kSecValueData as String] = seed
        let status = operations.add(query)
        // Duplicate items are never silently overwritten or deleted to create a new account.
        guard status == errSecSuccess else { throw TestAccountStorageError.keychain(status) }
    }
    func load(context: LAContext? = nil) throws -> Data? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context { query[kSecUseAuthenticationContext as String] = context }
        else {
            let noninteractive = LAContext()
            noninteractive.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = noninteractive
        }
        let (status, data) = operations.copy(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TestAccountStorageError.keychain(status) }
        guard let data, data.count == 32 else { throw TestAccountStorageError.invalidSeed }
        return data
    }
    func delete() throws {
        let status = operations.delete(identity)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TestAccountStorageError.keychain(status) }
    }
}
