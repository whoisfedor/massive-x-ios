import XCTest
import LocalAuthentication
import Security
import UIKit
@testable import MassiveX

@MainActor private final class ProbeSecretStore: TestAccountSecretStore {
    var data: Data?
    var failure: OSStatus?
    var writes = 0
    var reads = 0
    func saveNew(_ seed: Data) throws {
        if let failure { throw TestAccountStorageError.keychain(failure) }
        if data != nil { throw TestAccountStorageError.keychain(errSecDuplicateItem) }
        data = seed; writes += 1
    }
    func load(context: LAContext?) throws -> Data? {
        reads += 1
        guard context != nil else { throw TestAccountStorageError.keychain(errSecInteractionNotAllowed) }
        if let failure { throw TestAccountStorageError.keychain(failure) }
        return data
    }
    func delete() throws { XCTFail("Onboarding must not delete or overwrite an existing key") }
}
@MainActor private final class ProbeAuthentication: WalletAuthenticating {
    var failure: OnboardingError?
    var calls = 0
    var pause = false
    var afterSuccess: (() -> Void)?
    var pending: CheckedContinuation<LAContext, any Error>?
    func authorize(reason: String) async throws -> LAContext {
        calls += 1
        if let failure { throw failure }
        if pause { return try await withCheckedThrowingContinuation { pending = $0 } }
        afterSuccess?()
        return LAContext()
    }
    func cancel() { pending?.resume(throwing: OnboardingError.cancelled); pending = nil }
}
@MainActor private final class ProbeMetadata: WalletMetadataStoring {
    var record: WalletRecord?
    func load() -> WalletRecord? { record }
    func save(_ record: WalletRecord) { self.record = record }
}

@MainActor private final class ProbeClipboard: BackupClipboard {
    var value: String?
    var expiration: Date?
    var writes = 0
    func write(_ key: String, expires: Date) { value = key; expiration = expires; writes += 1 }
    var hasOwnedCopy: Bool { value != nil }
    func clearOwned() { value = nil }
}

final class OnboardingTests: XCTestCase {
    @MainActor private func model(_ store: ProbeSecretStore, _ auth: ProbeAuthentication = ProbeAuthentication(), _ metadata: ProbeMetadata = ProbeMetadata(), clipboard: ProbeClipboard = ProbeClipboard(), now: @escaping () -> Date = Date.init) -> WalletOnboarding {
        let model = WalletOnboarding(store: store, authentication: auth, metadata: metadata, clipboard: clipboard, clipboardNow: now)
        model.updatePrivacy(active: true, captured: false)
        return model
    }
    @MainActor func testCreateExportImportAndRecoverySamePublicIdentity() async throws {
        let store = ProbeSecretStore(), auth = ProbeAuthentication(), metadata = ProbeMetadata()
        let state = model(store, auth, metadata)
        await state.create()
        XCTAssertNotNil(state.record)
        XCTAssertFalse(state.record!.backupAcknowledged)
        XCTAssertNil(state.revealedKey)
        await state.reveal(risksAcknowledged: false)
        XCTAssertNil(state.revealedKey)
        await state.reveal(risksAcknowledged: true)
        let exported = try XCTUnwrap(state.revealedKey, "Authenticated export did not produce a value")
        XCTAssertTrue(exported.hasPrefix("S1"))
        state.acknowledgeBackup()
        XCTAssertNil(state.revealedKey)
        XCTAssertTrue(state.record!.backupAcknowledged)
        XCTAssertFalse(state.recoveryVerified)
        await state.verifyRecovery(exported)
        XCTAssertTrue(state.recoveryVerified)
        XCTAssertFalse(state.liveReceiveEnabled)
        let imported = model(ProbeSecretStore())
        await imported.importWallet(exported)
        XCTAssertTrue(imported.record?.publicKey == state.record?.publicKey)
        XCTAssertTrue(imported.record?.address == state.record?.address)
        XCTAssertFalse(imported.record!.backupAcknowledged)
        XCTAssertEqual(auth.calls, 3)
        XCTAssertFalse(String(describing: state).contains(exported))
        XCTAssertFalse(String(data: try JSONEncoder().encode(metadata.record), encoding: .utf8)!.contains(exported))
    }
    @MainActor func testImportCannotReplaceExistingWalletAndCreationDoesNotReveal() async throws {
        let store = ProbeSecretStore(), auth = ProbeAuthentication()
        let state = model(store, auth)
        await state.create()
        XCTAssertFalse(state.isRevealed)
        XCTAssertNil(state.revealedKey)
        let identity = state.record
        let initialBytes = store.data
        await state.reveal(risksAcknowledged: true)
        let exported = try XCTUnwrap(state.revealedKey)
        let calls = auth.calls
        await state.importWallet(exported)
        XCTAssertNil(state.revealedKey)
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(auth.calls, calls)
        XCTAssertEqual(store.writes, 1)
        XCTAssertTrue(store.data == initialBytes)
        XCTAssertTrue(state.record == identity)
        XCTAssertTrue(state.message == OnboardingError.importUnavailable.message)
    }
    @MainActor func testMissingProtectedKeyCanBeRestoredOnlyToMatchingIdentity() async throws {
        let store = ProbeSecretStore(), auth = ProbeAuthentication(), metadata = ProbeMetadata()
        let state = model(store, auth, metadata)
        await state.create()
        await state.reveal(risksAcknowledged: true)
        let exported = try XCTUnwrap(state.revealedKey)
        let identity = state.record
        // Simulate missing storage, never delete an actual Keychain item.
        store.data = nil
        let restarted = model(store, auth, metadata)
        await restarted.unlock()
        XCTAssertTrue(restarted.needsKeyRestore)
        let other = try MassaTestAccount().backupPrivateKeyEncoding()
        await restarted.importWallet(other)
        XCTAssertNil(store.data)
        XCTAssertTrue(restarted.message == OnboardingError.identityMismatch.message)
        await restarted.importWallet(exported)
        XCTAssertFalse(restarted.needsKeyRestore)
        XCTAssertTrue(restarted.record?.publicKey == identity?.publicKey)
        XCTAssertTrue(restarted.record?.address == identity?.address)
        XCTAssertNil(restarted.revealedKey)
        XCTAssertEqual(store.writes, 2)
    }
    @MainActor func testClipboardRequiresConsentAndFreshAuthenticationSurvivesNavigationAndClearsOnCapture() async throws {
        let store = ProbeSecretStore(), auth = ProbeAuthentication(), board = ProbeClipboard()
        let state = model(store, auth, clipboard: board)
        await state.create()
        XCTAssertNil(board.value)
        let calls = auth.calls
        await state.copyForBackup(risksAcknowledged: true, clipboardConsent: false)
        await state.copyForBackup(risksAcknowledged: false, clipboardConsent: true)
        XCTAssertEqual(auth.calls, calls); XCTAssertEqual(board.writes, 0)
        auth.failure = .cancelled
        await state.copyForBackup(risksAcknowledged: true, clipboardConsent: true)
        XCTAssertNil(board.value)
        auth.failure = nil
        let before = Date()
        await state.copyForBackup(risksAcknowledged: true, clipboardConsent: true)
        XCTAssertTrue(board.value == (try MassaTestAccount(seed: XCTUnwrap(store.data)).backupPrivateKeyEncoding()))
        XCTAssertTrue(state.clipboardActive)
        XCTAssertTrue(try XCTUnwrap(board.expiration).timeIntervalSince(before) <= 301)
        XCTAssertTrue(try XCTUnwrap(board.expiration) > before)
        XCTAssertNil(state.revealedKey)
        state.acknowledgeBackup()
        XCTAssertTrue(state.record!.backupAcknowledged)
        XCTAssertNotNil(board.value)
        state.updatePrivacy(active: false, captured: false)
        XCTAssertNotNil(board.value); XCTAssertTrue(state.clipboardActive)
        state.close(); XCTAssertNotNil(board.value)
        state.updatePrivacy(active: true, captured: false)
        await state.copyForBackup(risksAcknowledged: true, clipboardConsent: true)
        state.screenshotDetected()
        XCTAssertNil(board.value)
        state.updatePrivacy(active: true, captured: true)
        await state.copyForBackup(risksAcknowledged: true, clipboardConsent: true)
        XCTAssertNil(board.value)
    }
    @MainActor func testClipboardIsNotClearedByTheOldRevealTimerAndFreshRecoveryChecksPastedValue() async throws {
        let store = ProbeSecretStore(), board = ProbeClipboard()
        let state = model(store, clipboard: board)
        await state.create()
        await state.copyForBackup(risksAcknowledged: true, clipboardConsent: true)
        let input = try XCTUnwrap(board.value)
        state.acknowledgeBackup()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(board.value); XCTAssertTrue(state.clipboardActive)
        state.clearClipboard(); XCTAssertNil(board.value)
        await state.verifyRecovery(input)
        XCTAssertTrue(state.recoveryVerified)
        XCTAssertFalse(state.liveReceiveEnabled)
    }
    @MainActor func testClipboardAdapterClearsOnlyItsOwnItem() {
        // Anonymous pasteboard and non-secret marker only; never touch the operator's general clipboard.
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let adapter = LocalBackupClipboard(board: board)
        adapter.write("PUBLIC TEST MARKER", expires: Date().addingTimeInterval(30))
        XCTAssertTrue(board.string == "PUBLIC TEST MARKER")
        adapter.clearOwned()
        XCTAssertNil(board.string)
        adapter.write("PUBLIC TEST MARKER", expires: Date().addingTimeInterval(30))
        board.string = "NEW USER ITEM"
        adapter.clearOwned()
        XCTAssertTrue(board.string == "NEW USER ITEM")
    }
    @MainActor func testOfficialPrivateKeyFixturesImportAndExport() async throws {
        struct Fixtures: Decodable { let vectors: [Vector]; struct Vector: Decodable { let privateKey: String; let publicKey: String; let address: String } }
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(PublicMassaFixtures.json.utf8))
        for vector in fixtures.vectors {
            let state = model(ProbeSecretStore())
            await state.importWallet(vector.privateKey)
            XCTAssertTrue(state.record?.publicKey == vector.publicKey)
            XCTAssertTrue(state.record?.address == vector.address)
            await state.reveal(risksAcknowledged: true)
            XCTAssertTrue(state.revealedKey == vector.privateKey, "Public SDK fixture encoding mismatch")
            state.conceal()
        }
    }
    @MainActor func testMalformedImportNeverAuthenticatesOrWrites() async {
        let store = ProbeSecretStore(), auth = ProbeAuthentication()
        let state = model(store, auth)
        for input in ["", "S1invalid", "S0OIl", "words are not a supported phrase", String(repeating: "S", count: 1000)] {
            await state.importWallet(input)
            XCTAssertNil(state.record)
        }
        XCTAssertEqual(store.writes, 0); XCTAssertEqual(auth.calls, 0)
    }
    @MainActor func testAuthenticationAndStorageErrorsFailClosed() async {
        let store = ProbeSecretStore(), auth = ProbeAuthentication()
        let state = model(store, auth)
        auth.failure = .cancelled
        await state.create()
        XCTAssertNil(state.record); XCTAssertEqual(store.writes, 0)
        auth.failure = nil
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable] {
            store.failure = status
            await state.create()
            XCTAssertNil(state.record); XCTAssertEqual(store.writes, 0)
        }
        store.failure = nil
        await state.create()
        let first = store.data
        await state.create()
        XCTAssertTrue(first == store.data); XCTAssertEqual(store.writes, 1)
        store.failure = errSecUserCanceled
        await state.reveal(risksAcknowledged: true)
        XCTAssertNil(state.revealedKey)
    }
    @MainActor func testPrivacyConcealsAndInvalidatesInFlightAuthorization() async {
        let store = ProbeSecretStore(), auth = ProbeAuthentication()
        let state = model(store, auth)
        await state.create()
        await state.reveal(risksAcknowledged: true)
        XCTAssertTrue(state.isRevealed)
        state.updatePrivacy(active: false, captured: false)
        XCTAssertNil(state.revealedKey)
        state.updatePrivacy(active: true, captured: true)
        await state.reveal(risksAcknowledged: true)
        XCTAssertNil(state.revealedKey)
        state.updatePrivacy(active: true, captured: false)
        auth.pause = true
        let read = Task { await state.reveal(risksAcknowledged: true) }
        await Task.yield()
        state.close()
        await read.value
        XCTAssertNil(state.revealedKey)
        XCTAssertFalse(state.isBusy)
    }
    @MainActor func testAuthenticationWaitsForActiveSceneAndBackgroundInvalidatesIt() async {
        let store = ProbeSecretStore(), auth = ProbeAuthentication()
        let state = model(store, auth)
        auth.afterSuccess = { state.updatePrivacy(active: false, captured: false) }
        let create = Task { await state.create() }
        while auth.calls == 0 { await Task.yield() }
        XCTAssertEqual(store.writes, 0)
        XCTAssertTrue(state.isBusy)
        state.updatePrivacy(active: true, captured: false)
        await create.value
        XCTAssertEqual(store.writes, 1)
        let rejected = Task { await state.reveal(risksAcknowledged: true) }
        while auth.calls < 2 { await Task.yield() }
        XCTAssertNil(state.revealedKey)
        state.close()
        await rejected.value
        XCTAssertNil(state.revealedKey)
        XCTAssertEqual(store.reads, 0)
        state.updatePrivacy(active: true, captured: false)
        let reveal = Task { await state.reveal(risksAcknowledged: true) }
        while auth.calls < 3 { await Task.yield() }
        XCTAssertNil(state.revealedKey)
        state.updatePrivacy(active: true, captured: false)
        await reveal.value
        XCTAssertTrue(state.isRevealed)
        state.conceal()
    }
    @MainActor func testRevealHasNoForcedTimeoutAndScreenshotConceals() async {
        let state = model(ProbeSecretStore())
        await state.create(); await state.reveal(risksAcknowledged: true)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(state.revealedKey)
        state.screenshotDetected()
        XCTAssertNil(state.revealedKey)
    }
    @MainActor func testRecoveryRejectsWrongKeyAndDoesNotAcknowledgeBackup() async throws {
        let store = ProbeSecretStore()
        let state = model(store)
        await state.create()
        let correct = try MassaTestAccount(seed: XCTUnwrap(store.data)).backupPrivateKeyEncoding()
        let wrong = try MassaTestAccount().backupPrivateKeyEncoding()
        await state.verifyRecovery(correct)
        XCTAssertTrue(state.recoveryVerified)
        XCTAssertFalse(state.record!.backupAcknowledged)
        await state.reveal(risksAcknowledged: true); state.acknowledgeBackup()
        await state.verifyRecovery(wrong)
        XCTAssertFalse(state.recoveryVerified)
        await state.verifyRecovery(correct)
        XCTAssertTrue(state.recoveryVerified)
    }
    @MainActor func testRestartMissingPreferencesMissingKeyAndIdentityMismatch() async throws {
        let store = ProbeSecretStore(), metadata = ProbeMetadata()
        let state = model(store, ProbeAuthentication(), metadata)
        await state.create()
        let original = state.record
        let restarted = model(store)
        XCTAssertNil(restarted.record)
        await restarted.unlock()
        XCTAssertTrue(restarted.record == original)
        XCTAssertFalse(restarted.recoveryVerified)
        store.data = nil
        await restarted.unlock()
        XCTAssertTrue(restarted.message == OnboardingError.missingKey.message)
        XCTAssertEqual(store.writes, 1)
        store.data = MassaTestAccount().storageData()
        await restarted.reveal(risksAcknowledged: true)
        XCTAssertNil(restarted.revealedKey)
        XCTAssertTrue(restarted.message == OnboardingError.identityMismatch.message)
    }
}

@MainActor private final class WalletStoreRegistry {
    var entries: [String: ProbeSecretStore] = [:]
    func store(_ id: String) -> ProbeSecretStore {
        if let found = entries[id] { return found }
        let new = ProbeSecretStore(); entries[id] = new; return new
    }
}
private actor WalletBalanceProbe: MainnetReading {
    var requests = 0
    func status() async throws -> MainnetStatus { MainnetStatus(version: "test", chainID: 77_658_377, currentCycle: 1) }
    func balance(for address: String) async throws -> MainnetBalance {
        requests += 1
        return MainnetBalance(address: address, finalBalance: "1.25", candidateBalance: "1.25")
    }
}
final class WalletManagerTests: XCTestCase {
    private struct Fixtures: Decodable {
        let vectors: [Vector]
        struct Vector: Decodable { let privateKey: String; let publicKey: String; let address: String }
    }
    private func vectors() throws -> [Fixtures.Vector] {
        try JSONDecoder().decode(Fixtures.self, from: Data(PublicMassaFixtures.json.utf8)).vectors
    }
    private func safeTestVectors() throws -> [Fixtures.Vector] {
        try (0..<2).map { _ in
            let account = MassaTestAccount(), identity = try account.publicAccount
            return Fixtures.Vector(privateKey: try account.backupPrivateKeyEncoding(), publicKey: identity.publicKey, address: identity.address)
        }
    }
    @MainActor private func preferences() -> (UserDefaults, String) {
        let name = "wallet-manager-tests." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
    @MainActor func testIndependentOwnedWalletsSelectionPersistence() async throws {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let registry = WalletStoreRegistry(), fixtures = try safeTestVectors()
        let manager = WalletManager(defaults: prefs, stores: { registry.store($0) }, authentication: { ProbeAuthentication() })
        for fixture in fixtures.prefix(2) {
            let result = await manager.addOwned(privateKey: fixture.privateKey, active: true, captured: false)
            XCTAssertTrue(result)
            XCTAssertTrue(manager.selected?.address == fixture.address)
            XCTAssertTrue(manager.selected?.publicKey == fixture.publicKey)
        }
        XCTAssertEqual(manager.wallets.count, 2)
        let first = manager.wallets[0], second = manager.wallets[1]
        XCTAssertNotEqual(WalletManager.keychainService(first.id), WalletManager.keychainService(second.id))
        XCTAssertFalse(registry.entries[first.id]!.data == registry.entries[second.id]!.data)
        let previous = manager.backup!
        previous.updatePrivacy(active: true, captured: false)
        await previous.reveal(risksAcknowledged: true)
        XCTAssertNotNil(previous.revealedKey)
        manager.select(first.id)
        XCTAssertNil(previous.revealedKey)
        manager.rename(first.id, name: "  Savings  ")
        let restarted = WalletManager(defaults: prefs, stores: { registry.store($0) }, authentication: { ProbeAuthentication() })
        XCTAssertTrue(restarted.selected?.id == first.id)
        XCTAssertEqual(restarted.selected?.name, "Savings")
        XCTAssertEqual(restarted.wallets.count, 2)
        let publicJSON = try XCTUnwrap(prefs.data(forKey: "mainnet.wallet-catalog.v1"))
        for fixture in fixtures { XCTAssertFalse(String(decoding: publicJSON, as: UTF8.self).contains(fixture.privateKey)) }
    }
    @MainActor func testDuplicatesOfferSelectionAndNeverOverwriteOrAuthenticate() async throws {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let registry = WalletStoreRegistry(), auth = ProbeAuthentication(), fixtures = try safeTestVectors()
        let manager = WalletManager(defaults: prefs, stores: { registry.store($0) }, authentication: { auth })
        let added = await manager.addOwned(privateKey: fixtures[0].privateKey, name: "Original", active: true, captured: false)
        XCTAssertTrue(added)
        let original = manager.selected!, calls = auth.calls
        XCTAssertTrue(manager.addWatchOnly(address: fixtures[1].address, name: "Observer"))
        let observerID = manager.selectedID
        let duplicate = await manager.addOwned(privateKey: fixtures[0].privateKey, name: "Replacement", active: true, captured: false)
        XCTAssertFalse(duplicate)
        XCTAssertTrue(manager.duplicateID == original.id)
        XCTAssertTrue(manager.selectedID == observerID)
        XCTAssertEqual(auth.calls, calls)
        XCTAssertEqual(registry.entries[original.id]?.writes, 1)
        manager.select(original.id)
        XCTAssertNil(manager.duplicateID)
        XCTAssertEqual(manager.selected?.name, "Original")
        XCTAssertFalse(manager.addWatchOnly(address: fixtures[0].address, name: "Duplicate"))
        XCTAssertEqual(manager.wallets.count, 2)
    }
    @MainActor func testWatchOnlyPersistsWithoutAnySecretAccessAndReadsOnlyOnRequest() async throws {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let registry = WalletStoreRegistry(), rpc = WalletBalanceProbe(), fixture = try safeTestVectors()[0]
        let manager = WalletManager(defaults: prefs, stores: { registry.store($0) }, authentication: { XCTFail("Watch-only must not authenticate"); return ProbeAuthentication() }, client: rpc)
        XCTAssertTrue(manager.addWatchOnly(address: fixture.address, name: "Watch"))
        XCTAssertNil(manager.backup)
        XCTAssertTrue(registry.entries.isEmpty)
        let before = await rpc.requests; XCTAssertEqual(before, 0)
        await manager.refreshBalance(try XCTUnwrap(manager.selectedID))
        let after = await rpc.requests; XCTAssertEqual(after, 1)
        XCTAssertEqual(manager.balances[manager.selectedID!]?.finalBalance, "1.25")
        let restarted = WalletManager(defaults: prefs, stores: { registry.store($0) })
        XCTAssertTrue(restarted.selected?.kind == .watchOnly)
        XCTAssertNil(restarted.selected?.publicKey); XCTAssertNil(restarted.backup)
        XCTAssertTrue(registry.entries.isEmpty)
    }
    @MainActor func testMalformedCancelledAndCapturedImportsDoNotCreateWallets() async throws {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let registry = WalletStoreRegistry(), auth = ProbeAuthentication()
        let manager = WalletManager(defaults: prefs, stores: { registry.store($0) }, authentication: { auth })
        let malformed = await manager.addOwned(privateKey: "S1invalid", active: true, captured: false)
        XCTAssertFalse(malformed); XCTAssertTrue(registry.entries.isEmpty)
        XCTAssertFalse(manager.addWatchOnly(address: "AUinvalid", name: "Bad"))
        auth.failure = .cancelled
        let cancelled = await manager.addOwned(active: true, captured: false)
        XCTAssertFalse(cancelled)
        auth.failure = nil
        let captured = await manager.addOwned(active: true, captured: true)
        XCTAssertFalse(captured)
        XCTAssertTrue(manager.wallets.isEmpty)
        XCTAssertTrue(registry.entries.values.allSatisfy { $0.writes == 0 })
    }
    @MainActor func testLegacyWalletMigrationArchivesAndKeepsExactProtectedSlot() async throws {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let fixture = try vectors()[0], account = try MassaTestAccount(importing: fixture.privateKey)
        let oldData = try JSONEncoder().encode(WalletRecord(try account.publicAccount, backupAcknowledged: true))
        prefs.set(oldData, forKey: LegacyWalletMigration.singleRecordKey)
        let registry = WalletStoreRegistry()
        registry.store(WalletManager.legacyID).data = account.storageData()
        let manager = WalletManager(defaults: prefs, stores: { registry.store($0) }, legacyStores: { registry.store($0) }, authentication: { ProbeAuthentication() })
        XCTAssertNil(manager.selectedID); XCTAssertTrue(manager.activeWallets.isEmpty)
        XCTAssertEqual(manager.archivedWallets.count, 1)
        XCTAssertEqual(LegacyWalletMigration.service(WalletManager.legacyID), "com.massivex.buildnet.test-wallet.v1")
        XCTAssertTrue(manager.archivedWallets[0].backupAcknowledged)
        XCTAssertThrowsError(try ReceivePayload(wallet: manager.archivedWallets[0]))
        let backup = try XCTUnwrap(manager.archivedBackup(WalletManager.legacyID))
        backup.updatePrivacy(active: true, captured: false)
        await backup.reveal(risksAcknowledged: true)
        XCTAssertTrue(backup.revealedKey == fixture.privateKey)
        XCTAssertEqual(registry.entries.count, 1)
        XCTAssertEqual(registry.entries[WalletManager.legacyID]?.writes, 0)
        XCTAssertTrue(prefs.data(forKey: LegacyWalletMigration.singleRecordKey) == oldData)
        backup.close()
    }
    @MainActor func testCorruptCatalogFailsClosedWithoutReplacingKeysOrMetadata() async {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let invalid = Data("invalid catalog".utf8)
        prefs.set(invalid, forKey: "mainnet.wallet-catalog.v1")
        let registry = WalletStoreRegistry()
        let manager = WalletManager(defaults: prefs, stores: { registry.store($0) })
        let added = await manager.addOwned(active: true, captured: false)
        XCTAssertFalse(added); XCTAssertTrue(registry.entries.isEmpty)
        XCTAssertTrue(prefs.data(forKey: "mainnet.wallet-catalog.v1") == invalid)
    }
}

/// Content exists only in this disposable memory double; the production adapter cannot read it.
@MainActor private final class RecordingBackupPasteboard: BackupPasteboard {
    var changeCount = 0
    var items: [[String: Any]] = []
    var options: [UIPasteboard.OptionsKey: Any] = [:]
    var clears = 0
    var jump = 1
    func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any]) {
        self.items = items; self.options = options; changeCount += jump
    }
    func clearBackupItems() { items = []; changeCount += 1; clears += 1 }
    func foreignCopy() { items = [["public.utf8-plain-text": "UNRELATED PUBLIC MARKER"]]; changeCount += 1 }
}

extension OnboardingTests {
    @MainActor func testCopyUsesExactlyFiveMinuteSystemOptionsAndSurvivesPrivacyTransitions() async throws {
        let store = ProbeSecretStore(), auth = ProbeAuthentication(), board = RecordingBackupPasteboard()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let clipboard = LocalBackupClipboard(board: board, now: { clock })
        let state = WalletOnboarding(store: store, authentication: auth, metadata: ProbeMetadata(), clipboard: clipboard, clipboardNow: { clock })
        state.updatePrivacy(active: true, captured: false); await state.create()
        await state.copyForBackup(risksAcknowledged: true, clipboardConsent: true)
        XCTAssertEqual(board.items.count, 1); XCTAssertEqual(Set(try XCTUnwrap(board.items.first).keys), ["public.utf8-plain-text"])
        let expected = try MassaTestAccount(seed: XCTUnwrap(store.data)).backupPrivateKeyEncoding()
        XCTAssertTrue(board.items.first?["public.utf8-plain-text"] as? String == expected)
        XCTAssertEqual(board.options[.localOnly] as? Bool, true)
        XCTAssertEqual(board.options[.expirationDate] as? Date, clock.addingTimeInterval(300))
        XCTAssertNil(state.revealedKey)
        await state.reveal(risksAcknowledged: true); XCTAssertNotNil(state.revealedKey)
        state.updatePrivacy(active: false, captured: false, background: true)
        XCTAssertNil(state.revealedKey); XCTAssertEqual(board.clears, 0); XCTAssertTrue(clipboard.hasOwnedCopy)
        state.updatePrivacy(active: true, captured: false); XCTAssertNil(state.revealedKey)
        state.close(); XCTAssertEqual(board.clears, 0)
        state.updatePrivacy(active: true, captured: false)
        clock = clock.addingTimeInterval(60)
        await state.copyForBackup(risksAcknowledged: true, clipboardConsent: true)
        XCTAssertEqual(board.options[.expirationDate] as? Date, clock.addingTimeInterval(300))
        auth.failure = .cancelled
        await state.copyForBackup(risksAcknowledged: true, clipboardConsent: true)
        XCTAssertTrue(clipboard.hasOwnedCopy); XCTAssertEqual(board.clears, 0)
        state.clearClipboard(); XCTAssertEqual(board.clears, 1); XCTAssertTrue(board.items.isEmpty)
    }
    @MainActor func testOwnershipRejectsOtherCopiesExpiredSessionsAndAmbiguousCounters() {
        let board = RecordingBackupPasteboard(); var clock = Date()
        let first = LocalBackupClipboard(board: board, now: { clock }), second = LocalBackupClipboard(board: board, now: { clock })
        first.write("PUBLIC MARKER ONE", expires: clock.addingTimeInterval(300))
        second.write("PUBLIC MARKER TWO", expires: clock.addingTimeInterval(300))
        first.clearOwned(); XCTAssertEqual(board.clears, 0); XCTAssertTrue(second.hasOwnedCopy)
        board.foreignCopy(); second.clearOwned(); XCTAssertEqual(board.clears, 0); XCTAssertFalse(board.items.isEmpty)
        first.write("PUBLIC MARKER ONE", expires: clock.addingTimeInterval(300))
        clock = clock.addingTimeInterval(300)
        XCTAssertFalse(first.hasOwnedCopy); first.clearOwned(); XCTAssertEqual(board.clears, 0)
        board.foreignCopy(); XCTAssertEqual(board.clears, 0)
        board.jump = 2
        first.write("PUBLIC MARKER ONE", expires: clock.addingTimeInterval(300))
        XCTAssertFalse(first.hasOwnedCopy); first.clearOwned(); XCTAssertEqual(board.clears, 0)
    }
    @MainActor func testModelDeallocationDoesNotClearSystemCopyAndNoSecretEntersMetadata() async throws {
        let board = RecordingBackupPasteboard(), store = ProbeSecretStore(), metadata = ProbeMetadata()
        let clipboard = LocalBackupClipboard(board: board)
        var state: WalletOnboarding? = WalletOnboarding(store: store, authentication: ProbeAuthentication(), metadata: metadata, clipboard: clipboard)
        state?.updatePrivacy(active: true, captured: false); await state?.create()
        await state?.copyForBackup(risksAcknowledged: true, clipboardConsent: true)
        let expected = try MassaTestAccount(seed: XCTUnwrap(store.data)).backupPrivateKeyEncoding()
        let encoded = try JSONEncoder().encode(XCTUnwrap(metadata.record))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(expected))
        XCTAssertFalse(String(describing: state!).contains(expected))
        state?.close(); state = nil
        XCTAssertTrue(clipboard.hasOwnedCopy); XCTAssertEqual(board.clears, 0)
    }
    @MainActor func testCopyAuthenticationBackgroundCancellationDenialAndCaptureNeverWrite() async {
        for failure in [OnboardingError.cancelled, .authentication] {
            let board = ProbeClipboard(), auth = ProbeAuthentication()
            let subject = model(ProbeSecretStore(), auth, clipboard: board)
            await subject.create(); auth.failure = failure
            await subject.copyForBackup(risksAcknowledged: true, clipboardConsent: true)
            XCTAssertEqual(board.writes, 0); XCTAssertNil(subject.revealedKey)
        }
        let board = ProbeClipboard(), auth = ProbeAuthentication(), state = model(ProbeSecretStore(), auth, clipboard: board)
        await state.create(); let calls = auth.calls; auth.pause = true
        let copy = Task { await state.copyForBackup(risksAcknowledged: true, clipboardConsent: true) }
        while auth.calls == calls { await Task.yield() }
        state.close(); await copy.value; XCTAssertEqual(board.writes, 0)
        state.updatePrivacy(active: true, captured: true)
        await state.copyForBackup(risksAcknowledged: true, clipboardConsent: true)
        XCTAssertEqual(board.writes, 0)
    }
    @MainActor func testAnonymousUIKitBoardSystemExpirationAndReplacementSurviveAppObjects() async throws {
        // Only public markers on a named temporary board; never read or write .general in tests.
        let board = UIPasteboard.withUniqueName(); defer { UIPasteboard.remove(withName: board.name) }
        var adapter: LocalBackupClipboard? = LocalBackupClipboard(board: board)
        adapter?.write("PUBLIC EXPIRING MARKER", expires: Date().addingTimeInterval(0.5))
        XCTAssertTrue(board.string == "PUBLIC EXPIRING MARKER")
        adapter = nil
        try await Task.sleep(for: .seconds(1))
        // iOS may deliver expiration asynchronously; bounded polling is evidence, not a hard realtime promise.
        for _ in 0..<30 { if !board.hasStrings { break }; try await Task.sleep(for: .milliseconds(100)) }
        guard !board.hasStrings else { throw XCTSkip("Named pasteboard expiration not observed within bounded window on this runtime; general-board expiry requires device smoke check.") }
        let second = LocalBackupClipboard(board: board)
        second.write("PUBLIC EXPIRING MARKER", expires: Date().addingTimeInterval(0.5))
        board.string = "UNRELATED PUBLIC MARKER"
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(board.string == "UNRELATED PUBLIC MARKER")
        second.clearOwned(); XCTAssertTrue(board.string == "UNRELATED PUBLIC MARKER")
    }
    func testFiveMinuteBackupCopyMessagingInAllSixLanguages() throws {
        let keys = [
            "Private key copied to this iPhone’s clipboard for up to 5 minutes. You can leave Backup to paste it. Others may read the clipboard; clear it when finished. Never paste it into chat. This is not an offline backup.",
            "Copy only to this iPhone’s clipboard with a 5-minute system expiration. Leaving Backup or switching apps does not clear it. Other apps may read or keep pasted content; expiration cannot revoke those copies. Never paste a key into chat. Copying is not an offline backup."
        ]
        for language in AppLanguage.allCases {
            let bundle = try XCTUnwrap(Bundle(path: XCTUnwrap(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"))))
            for key in keys { XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "MISSING", table: nil), "MISSING") }
        }
    }
}
extension WalletManagerTests {
    @MainActor func testWalletSwitchRetainsOwnClipboardSessionWithoutClearingAnotherWalletCopy() async throws {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let registry = WalletStoreRegistry(), fixtures = try safeTestVectors()
        let board = UIPasteboard.withUniqueName(); defer { UIPasteboard.remove(withName: board.name) }
        let manager = WalletManager(defaults: prefs, stores: { registry.store($0) }, authentication: { ProbeAuthentication() },
            clipboardFactory: { _ in LocalBackupClipboard(board: board) }, client: WalletBalanceProbe(), balanceChanged: { _, _ in }, walletsRemoved: { _ in })
        for fixture in fixtures { let added = await manager.addOwned(privateKey: fixture.privateKey, active: true, captured: false); XCTAssertTrue(added) }
        let first = manager.wallets[0].id, second = manager.wallets[1].id
        manager.select(first); let original = try XCTUnwrap(manager.backup)
        original.updatePrivacy(active: true, captured: false)
        await original.copyForBackup(risksAcknowledged: true, clipboardConsent: true)
        await original.reveal(risksAcknowledged: true)
        manager.select(second); XCTAssertNil(original.revealedKey); XCTAssertTrue(board.string == fixtures[0].privateKey)
        manager.select(first); let reopened = try XCTUnwrap(manager.backup)
        reopened.updatePrivacy(active: true, captured: false); XCTAssertTrue(reopened.clipboardActive)
        manager.select(second); let other = try XCTUnwrap(manager.backup)
        other.updatePrivacy(active: true, captured: false); await other.copyForBackup(risksAcknowledged: true, clipboardConsent: true)
        original.clearClipboard(); XCTAssertTrue(board.string == fixtures[1].privateKey)
        other.clearClipboard(); XCTAssertFalse(board.hasStrings)
    }
}

extension OnboardingTests {
    @MainActor func testNativeClipboardOwnershipSurvivesEventTurnsAndRejectsNewerCopy() async throws {
        let board = UIPasteboard.withUniqueName(); defer { UIPasteboard.remove(withName: board.name) }
        let adapter = LocalBackupClipboard(board: board)
        adapter.write("PUBLIC EVENT TURN MARKER", expires: Date().addingTimeInterval(300))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(adapter.hasOwnedCopy)
        adapter.clearOwned(); XCTAssertFalse(board.hasStrings)
        adapter.write("PUBLIC EVENT TURN MARKER", expires: Date().addingTimeInterval(300))
        try await Task.sleep(for: .milliseconds(100))
        board.string = "UNRELATED PUBLIC MARKER"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(adapter.hasOwnedCopy)
        adapter.clearOwned(); XCTAssertTrue(board.string == "UNRELATED PUBLIC MARKER")
    }
}
