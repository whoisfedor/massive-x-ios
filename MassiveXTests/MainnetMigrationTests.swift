import XCTest
import LocalAuthentication
@testable import MassiveX

@MainActor private final class MigrationStore: TestAccountSecretStore {
    var bytes: Data?
    var reads = 0
    func saveNew(_ seed: Data) throws { guard bytes == nil else { throw OnboardingError.alreadyExists }; bytes = seed }
    func load(context: LAContext?) throws -> Data? { reads += 1; return bytes }
    func delete() throws { XCTFail("Migration must never delete a key") }
}
@MainActor private final class MigrationAuth: WalletAuthenticating {
    func authorize(reason: String) async throws -> LAContext { LAContext() }
    func cancel() {}
}
private actor FailingMainnet: MainnetReading {
    var requests = 0
    func status() async throws -> MainnetStatus { throw MainnetRPCError.offline }
    func balance(for address: String) async throws -> MainnetBalance { requests += 1; throw MainnetRPCError.offline }
}
final class MainnetMigrationTests: XCTestCase {
    @MainActor func testMultiwalletPreviewCatalogIsPreservedAndQuarantined() async throws {
        let suite = "mainnet-migration." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let account = MassaTestAccount(), identity = try account.publicAccount, id = UUID().uuidString
        // Exact public shape from a22dbbc, with no Mainnet provenance fields.
        let old: [String: Any] = ["wallets": [["id": id, "name": "My preview", "address": identity.address,
            "publicKey": identity.publicKey, "kind": "owned", "network": "Buildnet", "backupAcknowledged": true]], "selectedID": id]
        let bytes = try JSONSerialization.data(withJSONObject: old)
        prefs.set(bytes, forKey: LegacyWalletMigration.catalogKey)
        let store = MigrationStore(); store.bytes = account.storageData()
        var legacyIDs: [String] = []
        let manager = WalletManager(defaults: prefs, stores: { _ in XCTFail("Must not access current namespace for archived keys"); return store },
            legacyStores: { legacyIDs.append($0); return store }, authentication: { MigrationAuth() })
        XCTAssertNil(manager.selected); XCTAssertNil(manager.selectedID); XCTAssertNil(manager.backup)
        XCTAssertEqual(manager.archivedWallets.count, 1)
        XCTAssertTrue(prefs.data(forKey: LegacyWalletMigration.catalogKey) == bytes)
        XCTAssertThrowsError(try ReceivePayload(wallet: manager.archivedWallets[0]))
        manager.select(id); XCTAssertNil(manager.selected)
        let backup = try XCTUnwrap(manager.archivedBackup(id))
        backup.updatePrivacy(active: true, captured: false)
        await backup.reveal(risksAcknowledged: true)
        XCTAssertTrue(backup.revealedKey == (try account.backupPrivateKeyEncoding()))
        XCTAssertEqual(legacyIDs, [id]); XCTAssertEqual(store.reads, 1)
        backup.close()
        let restarted = WalletManager(defaults: prefs)
        XCTAssertNil(restarted.selected); XCTAssertEqual(restarted.archivedWallets.count, 1)
    }
    @MainActor func testKnownPublicFixtureCannotBecomeFundableWallet() async throws {
        let suite = "mainnet-known-test." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let known = try MassaTestAccount(seed: Data(repeating: 0, count: 32)), identity = try known.publicAccount
        let manager = WalletManager(defaults: prefs, stores: { _ in XCTFail("Public test key must be rejected before storage"); return MigrationStore() })
        let added = await manager.addOwned(privateKey: try known.backupPrivateKeyEncoding(), active: true, captured: false)
        XCTAssertFalse(added)
        XCTAssertFalse(manager.addWatchOnly(address: identity.address, name: "Known unsafe"))
        XCTAssertTrue(manager.activeWallets.isEmpty)
    }
    @MainActor func testOfflineStateHasNoFabricatedBalanceAndRefreshIsThrottled() async throws {
        let suite = "mainnet-offline." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let rpc = FailingMainnet(), manager = WalletManager(defaults: prefs, client: rpc)
        let identity = try MassaTestAccount().publicAccount
        XCTAssertTrue(manager.addWatchOnly(address: identity.address, name: "Observer"))
        let id = try XCTUnwrap(manager.selectedID)
        await manager.refreshBalance(id)
        await manager.refreshBalance(id)
        let count = await rpc.requests
        XCTAssertEqual(count, 1)
        XCTAssertNil(manager.balances[id]); XCTAssertNil(manager.lastUpdated[id])
        XCTAssertNotNil(manager.balanceErrors[id]); XCTAssertNil(manager.backup)
    }
}
