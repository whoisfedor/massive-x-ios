import XCTest
import LocalAuthentication
@testable import MassiveX

final class MassaYAMLImportTests: XCTestCase {
    private struct Fixture: Decodable { let yaml: String; let password: String }
    private func fixture() throws -> Fixture { try JSONDecoder().decode(Fixture.self, from: Data(PublicYAMLFixture.json.utf8)) }
    func testPinnedSDKVersionOneDecryptMatchesPublicIdentityAndBlockArrays() throws {
        let f = try fixture(), doc = try MassaYAMLImport.parse(Data(f.yaml.utf8))
        let account = try MassaYAMLImport.decrypt(doc, password: f.password)
        XCTAssertTrue(try account.publicAccount.address == doc.address)
        XCTAssertTrue(try Data([0]) + MassaCodec.decode(account.publicAccount.publicKey, prefix: "P") == doc.publicKey)
        var block = f.yaml
        for key in ["Salt", "Nonce", "CipheredData", "PublicKey"] {
            let line = block.components(separatedBy: .newlines).first { $0.hasPrefix(key + ":") }!
            let numbers = line.split(separator: "[", maxSplits: 1)[1].dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            block = block.replacingOccurrences(of: line, with: key + ":\n" + numbers.map { "  - " + $0 }.joined(separator: "\n"))
        }
        XCTAssertEqual(try MassaYAMLImport.parse(Data(block.utf8)).ciphertext, doc.ciphertext)
    }
    func testWrongPasswordTamperingAndDeclaredIdentityFailClosed() throws {
        let f = try fixture(), doc = try MassaYAMLImport.parse(Data(f.yaml.utf8))
        XCTAssertThrowsError(try MassaYAMLImport.decrypt(doc, password: "wrong"))
        var changed = doc.ciphertext; changed[0] ^= 1
        let tamper = MassaYAMLImport.Document(salt: doc.salt, nonce: doc.nonce, ciphertext: changed, publicKey: doc.publicKey, address: doc.address)
        XCTAssertThrowsError(try MassaYAMLImport.decrypt(tamper, password: f.password))
        var pub = doc.publicKey; pub[1] ^= 1
        let wrongPub = MassaYAMLImport.Document(salt: doc.salt, nonce: doc.nonce, ciphertext: doc.ciphertext, publicKey: pub, address: doc.address)
        XCTAssertThrowsError(try MassaYAMLImport.decrypt(wrongPub, password: f.password))
        let wrongAddress = try MassaPublicAccount(rawPublicKey: Data(repeating: 1, count: 32)).address
        let mismatch = MassaYAMLImport.Document(salt: doc.salt, nonce: doc.nonce, ciphertext: doc.ciphertext, publicKey: doc.publicKey, address: wrongAddress)
        XCTAssertThrowsError(try MassaYAMLImport.decrypt(mismatch, password: f.password))
    }
    func testMalformedMultipleAccountUnsupportedAndOversizeAreRejected() throws {
        let f = try fixture()
        for yaml in ["", f.yaml + "\nVersion: 1", f.yaml + "\n---\n" + f.yaml, "- " + f.yaml, f.yaml.replacingOccurrences(of: "Version: 1", with: "Version: 2"), f.yaml + "\nKDF: unsafe", f.yaml + "\nPublicKey: &alias", String(repeating: "x", count: MassaYAMLImport.maximumBytes + 1)] {
            XCTAssertThrowsError(try MassaYAMLImport.parse(Data(yaml.utf8)))
        }
    }
    func testCancelledDecryptionNeverReturnsAnAccount() async throws {
        let f = try fixture(), doc = try MassaYAMLImport.parse(Data(f.yaml.utf8))
        let task = Task { try Task.checkCancellation(); _ = try MassaYAMLImport.decrypt(doc, password: f.password); return true }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled import returned an account") } catch { XCTAssertTrue(error is CancellationError) }
    }
}

@MainActor private final class YAMLStore: TestAccountSecretStore {
    var bytes: Data?
    var fail = false
    var saves = 0
    func saveNew(_ data: Data) throws { if fail { throw TestAccountStorageError.keychain(-25291) }; guard bytes == nil else { throw OnboardingError.alreadyExists }; bytes = data; saves += 1 }
    func load(context: LAContext?) throws -> Data? { bytes }
    func delete() throws { XCTFail("Import must not delete an existing key") }
}
@MainActor private final class YAMLAuth: WalletAuthenticating {
    var fail = false
    var beforeApproval: (() -> Void)?
    func authorize(reason: String) async throws -> LAContext {
        beforeApproval?()
        if fail { throw OnboardingError.cancelled }
        return LAContext()
    }
    func cancel() {}
}
@MainActor extension MassaYAMLImportTests {
    func testDecryptedWalletUsesProtectedImportSelectsOnceAndPersistsWithoutBanner() async throws {
        let f = try fixture(), account = try MassaYAMLImport.decrypt(MassaYAMLImport.parse(Data(f.yaml.utf8)), password: f.password)
        let suite = "test.yaml.import." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = YAMLStore(), auth = YAMLAuth()
        let manager = WalletManager(defaults: prefs, stores: { _ in store }, authentication: { auth })
        let imported = await manager.addOwned(privateKey: try account.backupPrivateKeyEncoding(), name: WalletNamePresentation.importName("  "), active: true, captured: false)
        XCTAssertTrue(imported); XCTAssertEqual(manager.selected?.name, "Wallet"); XCTAssertNil(manager.message)
        XCTAssertTrue(manager.selected?.address == (try account.publicAccount.address)); XCTAssertEqual(store.saves, 1)
        let duplicate = await manager.addOwned(privateKey: try account.backupPrivateKeyEncoding(), name: "Duplicate", active: true, captured: false)
        XCTAssertFalse(duplicate); XCTAssertEqual(manager.activeWallets.count, 1); XCTAssertEqual(store.saves, 1)
        let restarted = WalletManager(defaults: prefs, stores: { _ in store }, authentication: { auth })
        XCTAssertEqual(restarted.selectedID, manager.selectedID); XCTAssertEqual(restarted.activeWallets.count, 1)
    }
    func testAuthenticationCancellationStorageFailureAndPrivacyLossDoNotPublishWallets() async throws {
        let f = try fixture(), account = try MassaYAMLImport.decrypt(MassaYAMLImport.parse(Data(f.yaml.utf8)), password: f.password)
        for scenario in 0..<4 {
            let suite = "test.yaml.failure." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
            defer { prefs.removePersistentDomain(forName: suite) }
            let store = YAMLStore(), auth = YAMLAuth()
            let manager = WalletManager(defaults: prefs, stores: { _ in store }, authentication: { auth })
            auth.fail = scenario == 0; store.fail = scenario == 1
            if scenario == 2 { auth.beforeApproval = { manager.creationPrivacy(active: false, captured: false, background: true) } }
            let imported = await manager.addOwned(privateKey: try account.backupPrivateKeyEncoding(), name: "Test", active: true, captured: scenario == 3)
            XCTAssertFalse(imported); XCTAssertTrue(manager.activeWallets.isEmpty); XCTAssertNil(manager.selectedID); XCTAssertEqual(store.saves, 0)
            XCTAssertTrue(WalletManager(defaults: prefs).activeWallets.isEmpty)
        }
    }
}

@MainActor extension MassaYAMLImportTests {
    func testActualImportSessionCommitsAndReportsProtectedStoreFailuresWithoutSilentReset() async throws {
        let f = try fixture(), document = try MassaYAMLImport.parse(Data(f.yaml.utf8))
        for scenario in 0..<3 {
            let suite = "test.yaml.session." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
            defer { prefs.removePersistentDomain(forName: suite) }
            let store = YAMLStore(), auth = YAMLAuth(), session = YAMLImportSession()
            store.fail = scenario == 1; auth.fail = scenario == 2
            let manager = WalletManager(defaults: prefs, stores: { _ in store }, authentication: { auth })
            let result = await session.importDocument(document, password: f.password, name: " ", wallets: manager, permitted: { true })
            XCTAssertEqual(result, scenario == 0); XCTAssertFalse(session.busy)
            if scenario == 0 {
                XCTAssertNil(session.failure); XCTAssertEqual(manager.selected?.name, "Wallet")
                XCTAssertTrue(manager.selected?.address == document.address)
                XCTAssertEqual(WalletManager(defaults: prefs).selectedID, manager.selectedID)
            } else { XCTAssertNotNil(session.failure); XCTAssertTrue(manager.activeWallets.isEmpty); XCTAssertEqual(store.saves, 0) }
        }
    }
    func testSessionWrongPasswordDuplicatePrivacyLossAndCancellationShowErrors() async throws {
        let f = try fixture(), document = try MassaYAMLImport.parse(Data(f.yaml.utf8))
        let suite = "test.yaml.session.errors." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = YAMLStore(), auth = YAMLAuth(), session = YAMLImportSession()
        let manager = WalletManager(defaults: prefs, stores: { _ in store }, authentication: { auth })
        let wrong = await session.importDocument(document, password: "wrong", name: "", wallets: manager, permitted: { true })
        XCTAssertFalse(wrong); XCTAssertNotNil(session.failure); XCTAssertEqual(store.saves, 0)
        let denied = await session.importDocument(document, password: f.password, name: "", wallets: manager, permitted: { false })
        XCTAssertFalse(denied); XCTAssertNotNil(session.failure); XCTAssertEqual(store.saves, 0)
        let task = Task { await session.importDocument(document, password: f.password, name: "", wallets: manager, permitted: { true }) }
        while !session.busy { await Task.yield() }
        session.cancel(); task.cancel(); let cancelled = await task.value
        XCTAssertFalse(cancelled); XCTAssertNotNil(session.failure); XCTAssertEqual(store.saves, 0)
        let added = await session.importDocument(document, password: f.password, name: "", wallets: manager, permitted: { true })
        XCTAssertTrue(added)
        let duplicate = await session.importDocument(document, password: f.password, name: "", wallets: manager, permitted: { true })
        XCTAssertFalse(duplicate); XCTAssertNotNil(session.failure); XCTAssertEqual(store.saves, 1)
    }
}
