import XCTest
import Security
import LocalAuthentication
@testable import MassiveX

@MainActor private final class KeychainMock: KeychainOperations {
    var data: Data?
    var status: OSStatus = errSecSuccess
    var added: [String: Any] = [:]
    var read: [String: Any] = [:]
    func add(_ query: [String: Any]) -> OSStatus {
        added = query
        if status != errSecSuccess { return status }
        if data != nil { return errSecDuplicateItem }
        data = query[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        read = query
        return (status == errSecSuccess && data == nil ? errSecItemNotFound : status, data)
    }
    func delete(_ query: [String: Any]) -> OSStatus { if status == errSecSuccess { data = nil }; return status }
}
final class KeychainTests: XCTestCase {
    @MainActor func testLifecycleAndPolicy() throws {
        let mock = KeychainMock()
        let store = TestAccountKeychain(operations: mock)
        XCTAssertNil(try store.load())
        try store.saveNew(Data(repeating: 0, count: 32))
        XCTAssertNotNil(mock.added[kSecAttrAccessControl as String])
        XCTAssertEqual(mock.added[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertTrue(try store.load() == Data(repeating: 0, count: 32))
        XCTAssertEqual((mock.read[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true)
        XCTAssertThrowsError(try store.saveNew(Data(repeating: 1, count: 32)))
        try store.delete()
        XCTAssertNil(try store.load())
    }
    @MainActor func testFailuresNeverBecomeMissingAccounts() throws {
        let mock = KeychainMock()
        let store = TestAccountKeychain(operations: mock)
        XCTAssertThrowsError(try store.saveNew(Data(count: 31)))
        for status in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed] {
            mock.status = status
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.saveNew(Data(count: 32)))
            XCTAssertThrowsError(try store.delete())
        }
        mock.status = errSecSuccess
        mock.data = Data(count: 31)
        XCTAssertThrowsError(try store.load())
    }
    @MainActor func testSimulatorProtectionProbeKeepsGateClosed() throws {
        #if targetEnvironment(simulator)
        let store = TestAccountKeychain(service: "com.massivex.public-storage-probe")
        try? store.delete()
        defer { try? store.delete() }
        var outcome = "Protected save succeeded; physical-device authentication still unverified."
        do {
            try store.saveNew(Data(repeating: 0, count: 32))
            do { _ = try store.load(); outcome += " Simulator unauthenticated read succeeded." }
            catch { outcome += " Simulator unauthenticated read rejected: \(error)." }
        } catch { outcome = "Simulator protected save rejected: \(error)." }
        let attachment = XCTAttachment(string: outcome)
        attachment.name = "Keychain protection probe (no secrets)"
        attachment.lifetime = .keepAlways
        add(attachment)
        #endif
    }
}

extension KeychainTests {
    @MainActor func testPhysicalWalletNamespacesStayIndependentAndProtected() throws {
        #if !targetEnvironment(simulator)
        // Disposable PUBLIC test bytes, unique test-only services; never inspect/delete an operator item.
        let nonce = UUID().uuidString
        let first = TestAccountKeychain(service: "com.massivex.security-test.\(nonce).first")
        let second = TestAccountKeychain(service: "com.massivex.security-test.\(nonce).second")
        defer { try? first.delete(); try? second.delete() }
        try first.saveNew(Data(repeating: 0, count: 32))
        try second.saveNew(Data(repeating: 1, count: 32))
        func denied(_ store: TestAccountKeychain) {
            do { _ = try store.load(); XCTFail("Protected read must not succeed without authorization") }
            catch TestAccountStorageError.keychain(let status) {
                XCTAssertTrue(status == errSecInteractionNotAllowed || status == errSecAuthFailed)
            } catch { XCTFail("Unexpected non-secret storage error") }
        }
        denied(first); denied(second)
        try first.delete()
        XCTAssertNil(try first.load())
        denied(second)
        #else
        throw XCTSkip("Requires physical passcode-protected iPhone; simulator does not verify this boundary")
        #endif
    }
}

extension KeychainTests {
    @MainActor func testLegacyAndMainnetQueryIdentifiersAreIndependent() throws {
        let old = KeychainMock(), current = KeychainMock(), id = UUID().uuidString
        let legacy = TestAccountKeychain(operations: old, service: LegacyWalletMigration.service(id), account: LegacyWalletMigration.account)
        let mainnet = TestAccountKeychain(operations: current, service: WalletManager.keychainService(id))
        try legacy.saveNew(Data(repeating: 0, count: 32)); try mainnet.saveNew(Data(repeating: 1, count: 32))
        XCTAssertNotEqual(old.added[kSecAttrService as String] as? String, current.added[kSecAttrService as String] as? String)
        XCTAssertNotEqual(old.added[kSecAttrAccount as String] as? String, current.added[kSecAttrAccount as String] as? String)
        XCTAssertEqual(old.added[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(current.added[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNotNil(old.added[kSecAttrAccessControl as String]); XCTAssertNotNil(current.added[kSecAttrAccessControl as String])
    }
}
