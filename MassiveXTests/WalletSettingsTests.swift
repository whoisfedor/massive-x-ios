import XCTest
import UserNotifications
import LocalAuthentication
import Security
@testable import MassiveX

@MainActor private final class NotificationProbe: BalanceNotificationDelivering {
    var permitted = true
    var ids: [String] = []
    var clears = 0
    func permission() async -> Bool { permitted }
    func requestPermission() async -> Bool { permitted }
    func deliver(identifier: String) async throws { ids.append(identifier) }
    func clear() { clears += 1 }
}
@MainActor private final class ResetAuthentication: WalletAuthenticating {
    func authorize(reason: String) async throws -> LAContext { LAContext() }
    func cancel() {}
}
@MainActor private final class ResetStore: TestAccountSecretStore {
    var data: Data?
    var deleted = 0
    var fails = false
    func saveNew(_ seed: Data) throws { data = seed }
    func load(context: LAContext?) throws -> Data? { data }
    func delete() throws {
        if fails { throw TestAccountStorageError.keychain(errSecNotAvailable) }
        data = nil; deleted += 1
    }
}

final class WalletSettingsTests: XCTestCase {
    @MainActor private func preferences() -> (UserDefaults, String) {
        let suite = "settings-07." + UUID().uuidString
        return (UserDefaults(suiteName: suite)!, suite)
    }
    func testPreferredCurrencyOrderPreservesOtherCurrencies() {
        XCTAssertEqual(Array(FiatCurrency.all.prefix(6)).map(\.id), ["USD", "EUR", "RUB", "BTC", "ETH", "SOL"])
        let rest = FiatCurrency.all.map(\.id).filter { !FiatCurrency.preferred.contains($0) }
        XCTAssertEqual(rest, Array(Set(Locale.commonISOCurrencyCodes)).sorted().filter { !FiatCurrency.preferred.contains($0) })
        XCTAssertEqual(Set(FiatCurrency.all.map(\.id)), Set(Locale.commonISOCurrencyCodes + ["BTC", "ETH", "SOL"]))
    }
    @MainActor func testLanguageSelectionPersistsIndependentOfGlobalPreferences() {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set("orange", forKey: "accentPalette"); prefs.set("JPY", forKey: "fiatCurrency")
        let settings = AppLanguageSettings(defaults: prefs)
        XCTAssertEqual(settings.language, .english)
        for language in AppLanguage.allCases {
            settings.select(language)
            XCTAssertEqual(AppLanguageSettings(defaults: prefs).language, language)
            XCTAssertEqual(language.locale.identifier, language.rawValue)
        }
        XCTAssertEqual(prefs.string(forKey: "accentPalette"), "orange")
        XCTAssertEqual(prefs.string(forKey: "fiatCurrency"), "JPY")
    }
    @MainActor func testNotificationsBaselineChangeDedupIsolationDisableAndRestart() async throws {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let delivery = NotificationProbe()
        var scheduled: [Bool] = []
        let model = BalanceNotifications(defaults: prefs, delivery: delivery, scheduleBackground: { scheduled.append($0) })
        let one = try MASAmount("1"), two = try MASAmount("2")
        await model.observe(walletID: "a", balance: one); XCTAssertTrue(delivery.ids.isEmpty)
        await model.setEnabled(true)
        await model.observe(walletID: "a", balance: one)
        await model.observe(walletID: "b", balance: two)
        XCTAssertTrue(delivery.ids.isEmpty)
        await model.observe(walletID: "a", balance: two)
        await model.observe(walletID: "a", balance: two)
        XCTAssertEqual(delivery.ids, ["balance.a"])
        let restarted = BalanceNotifications(defaults: prefs, delivery: delivery, scheduleBackground: { _ in })
        await restarted.observe(walletID: "a", balance: two)
        XCTAssertEqual(delivery.ids.count, 1)
        await model.setEnabled(false)
        await model.observe(walletID: "b", balance: one)
        XCTAssertEqual(delivery.ids.count, 1); XCTAssertEqual(scheduled, [true, false])
        XCTAssertFalse(BalanceNotifications(defaults: prefs, delivery: delivery, scheduleBackground: { _ in }).enabled)
    }
    @MainActor func testDeniedPermissionAndWalletRemovalDoNotAlert() async throws {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let delivery = NotificationProbe(); delivery.permitted = false
        let model = BalanceNotifications(defaults: prefs, delivery: delivery, scheduleBackground: { _ in })
        await model.setEnabled(true)
        await model.observe(walletID: "a", balance: try MASAmount("1"))
        await model.observe(walletID: "a", balance: try MASAmount("2"))
        XCTAssertTrue(delivery.ids.isEmpty); XCTAssertFalse(model.authorized)
        model.removeWallets(["a"]); delivery.permitted = true
        await model.observe(walletID: "a", balance: try MASAmount("3"))
        XCTAssertTrue(delivery.ids.isEmpty)
    }
    @MainActor func testResetCancellationThenScopedOwnedAndWatchCleanupPreservesUnknownArchive() async throws {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let archived = WalletRecord(try MassaTestAccount().publicAccount)
        let archiveData = try JSONEncoder().encode(archived)
        prefs.set(archiveData, forKey: LegacyWalletMigration.singleRecordKey)
        prefs.set("fr", forKey: "app.language"); prefs.set("JPY", forKey: "fiatCurrency"); prefs.set("orange", forKey: "accentPalette")
        let owned = ResetStore(), unrelated = ResetStore(); unrelated.data = Data(repeating: 9, count: 32)
        var services: [String] = [], removed: Set<String> = []
        let manager = WalletManager(defaults: prefs, stores: { services.append($0); return owned },
            legacyStores: { _ in XCTFail("Never touch archived Keychain"); return unrelated },
            authentication: { ResetAuthentication() }, balanceChanged: { _, _ in }, walletsRemoved: { removed.formUnion($0) })
        let added = await manager.addOwned(active: true, captured: false); XCTAssertTrue(added)
        let ownedID = try XCTUnwrap(manager.selectedID)
        XCTAssertTrue(manager.addWatchOnly(address: try MassaTestAccount().publicAccount.address, name: "Watch"))
        let watchID = try XCTUnwrap(manager.selectedID), before = prefs.data(forKey: "mainnet.wallet-catalog.v1")
        manager.removalPrivacy(active: true, captured: false)
        _ = manager.beginRemovalReview(); manager.cancelRemovalReview()
        XCTAssertNotNil(owned.data)
        XCTAssertEqual(before, prefs.data(forKey: "mainnet.wallet-catalog.v1"))
        manager.select(ownedID)
        let plan = try XCTUnwrap(manager.beginRemovalReview())

        let success = await manager.removeCurrentWallets(plan, acknowledged: true); XCTAssertTrue(success)
        XCTAssertNil(owned.data); XCTAssertEqual(owned.deleted, 1)
        XCTAssertFalse(services.contains(watchID)); XCTAssertEqual(removed, [ownedID])
        XCTAssertEqual(manager.activeWallets.map(\.id), [watchID]); XCTAssertEqual(manager.selectedID, watchID); XCTAssertNil(manager.backup)
        XCTAssertEqual(manager.archivedWallets.count, 1); XCTAssertEqual(unrelated.deleted, 0)
        XCTAssertEqual(prefs.data(forKey: LegacyWalletMigration.singleRecordKey), archiveData)
        XCTAssertEqual(prefs.string(forKey: "app.language"), "fr"); XCTAssertEqual(prefs.string(forKey: "fiatCurrency"), "JPY")
        XCTAssertEqual(prefs.string(forKey: "accentPalette"), "orange")
        XCTAssertTrue(manager.addWatchOnly(address: try MassaTestAccount().publicAccount.address, name: "New"))
        XCTAssertNotNil(manager.selectedID)
    }
    @MainActor func testFailedKeyDeletionRetainsRecoverableRecord() async throws {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let store = ResetStore()
        let manager = WalletManager(defaults: prefs, stores: { _ in store }, authentication: { ResetAuthentication() },
            balanceChanged: { _, _ in }, walletsRemoved: { _ in })
        let added = await manager.addOwned(active: true, captured: false); XCTAssertTrue(added)
        let id = manager.selectedID; store.fails = true
        manager.removalPrivacy(active: true, captured: false)
        let plan = try XCTUnwrap(manager.beginRemovalReview())
        let success = await manager.removeCurrentWallets(plan, acknowledged: true); XCTAssertFalse(success)
        XCTAssertNotNil(store.data); XCTAssertEqual(manager.selectedID, id)
        XCTAssertEqual(WalletManager(defaults: prefs, stores: { _ in store }).activeWallets.count, 1)
    }
}

extension WalletSettingsTests {
    func testNativeLocalizationResourcesContainEverySelectableLanguage() throws {
        for language in AppLanguage.allCases {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let label = bundle.localizedString(forKey: "Settings", value: nil, table: nil)
            if language != .english { XCTAssertNotEqual(label, "Settings") }
            let warning = bundle.localizedString(forKey: "Anyone with your private key controls the wallet. Losing the only copy can permanently remove access.", value: "MISSING", table: nil)
            XCTAssertNotEqual(warning, "MISSING")
            let purpose = bundle.localizedString(forKey: "NSFaceIDUsageDescription", value: "MISSING", table: "InfoPlist")
            XCTAssertNotEqual(purpose, "MISSING")
        }
    }
}

@MainActor private final class DeleteQueryProbe: KeychainOperations {
    var query: [String: Any] = [:]
    func add(_ query: [String: Any]) -> OSStatus { errSecSuccess }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) { (errSecItemNotFound, nil) }
    func delete(_ query: [String: Any]) -> OSStatus { self.query = query; return errSecSuccess }
}
extension WalletSettingsTests {
    @MainActor func testDeletionQueryIsNarrowAndDoesNotEnumerateKeys() throws {
        let id = UUID().uuidString, probe = DeleteQueryProbe()
        let store = TestAccountKeychain(operations: probe, service: WalletManager.keychainService(id))
        try store.delete()
        XCTAssertEqual(probe.query.count, 4)
        XCTAssertEqual(probe.query[kSecAttrService as String] as? String, "com.massivex.mainnet.wallet." + id)
        XCTAssertEqual(probe.query[kSecAttrAccount as String] as? String, "wallet-account")
        XCTAssertEqual(probe.query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(probe.query[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }
}

@MainActor private final class PausedNotificationProbe: BalanceNotificationDelivering {
    var pending: CheckedContinuation<Bool, Never>?
    var delivered = 0
    func permission() async -> Bool { await withCheckedContinuation { pending = $0 } }
    func requestPermission() async -> Bool { true }
    func deliver(identifier: String) async throws { delivered += 1 }
    func clear() {}
}
extension WalletSettingsTests {
    @MainActor func testDisablingInvalidatesInFlightNotificationPermission() async throws {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let probe = PausedNotificationProbe(), model = BalanceNotifications(defaults: prefs, delivery: probe, scheduleBackground: { _ in })
        await model.setEnabled(true)
        await model.observe(walletID: "public-test", balance: try MASAmount("1"))
        let pending = Task { await model.observe(walletID: "public-test", balance: try MASAmount("2")) }
        while probe.pending == nil { await Task.yield() }
        await model.setEnabled(false)
        probe.pending?.resume(returning: true); probe.pending = nil
        try await pending.value
        XCTAssertEqual(probe.delivered, 0)
    }
}

private actor ResetPausedRead: MainnetReading {
    var pending: CheckedContinuation<MainnetBalance, Never>?
    var address = ""
    func status() async throws -> MainnetStatus { MainnetStatus(version: "TEST", chainID: 77_658_377, currentCycle: 1) }
    func balance(for address: String) async throws -> MainnetBalance {
        self.address = address
        return await withCheckedContinuation { pending = $0 }
    }
    func isWaiting() -> Bool { pending != nil }
    func finish() { pending?.resume(returning: MainnetBalance(address: address, finalBalance: "1", candidateBalance: "1")); pending = nil }
}
extension WalletSettingsTests {
    @MainActor func testResetRejectsLateBalanceAndNotificationCallback() async throws {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let client = ResetPausedRead(), store = ResetStore(); var notifications = 0
        let manager = WalletManager(defaults: prefs, stores: { _ in store }, authentication: { ResetAuthentication() }, client: client, balanceChanged: { _, _ in notifications += 1 }, walletsRemoved: { _ in })
        let added = await manager.addOwned(name: "Disposable", active: true, captured: false); XCTAssertTrue(added)
        let id = try XCTUnwrap(manager.selectedID)
        let read = Task { await manager.refreshBalance(id) }
        while !(await client.isWaiting()) { await Task.yield() }
        manager.removalPrivacy(active: true, captured: false)
        let plan = try XCTUnwrap(manager.beginRemovalReview())
        let success = await manager.removeCurrentWallets(plan, acknowledged: true); XCTAssertTrue(success)
        await client.finish(); await read.value
        XCTAssertTrue(manager.balances.isEmpty); XCTAssertNil(manager.selectedID); XCTAssertEqual(notifications, 0)
    }
    @MainActor func testNativeNotificationPresentationDelegateInstalled() {
        XCTAssertTrue(UNUserNotificationCenter.current().delegate is MassiveXApplicationDelegate)
    }
}

extension WalletSettingsTests {
    @MainActor func testArchivedWalletIsMovedOutOfVisibleCatalogAndStaysHiddenOnRestart() throws {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let archivedAccount = MassaTestAccount(), currentAccount = MassaTestAccount()
        let archivedIdentity = try archivedAccount.publicAccount, currentIdentity = try currentAccount.publicAccount
        let archived = ManagedWallet(id: UUID().uuidString, name: "Wallet 1", address: archivedIdentity.address, publicKey: archivedIdentity.publicKey,
            kind: .owned, network: "Archived preview", backupAcknowledged: true, safety: .archivedPreview, storage: .legacy)
        let current = ManagedWallet(id: UUID().uuidString, name: "Current", address: currentIdentity.address, publicKey: currentIdentity.publicKey,
            kind: .owned, network: "Mainnet", backupAcknowledged: false)
        struct OldLayout: Encodable { let wallets: [ManagedWallet]; let selectedID: String }
        prefs.set(try JSONEncoder().encode(OldLayout(wallets: [archived, current], selectedID: current.id)), forKey: "mainnet.wallet-catalog.v1")
        let store = ResetStore(); store.data = currentAccount.storageData()
        let original = store.data
        func manager() -> WalletManager { WalletManager(defaults: prefs, stores: { id in
            XCTAssertEqual(id, current.id); return store
        }, legacyStores: { _ in XCTFail("Hidden archive must not access Keychain"); return store }) }
        let first = manager(), restarted = manager()
        for model in [first, restarted] {
            XCTAssertEqual(model.wallets.count, 1); XCTAssertTrue(model.wallets.allSatisfy { !$0.isQuarantined })
            XCTAssertEqual(model.selectedID, current.id)
            XCTAssertEqual(model.archivedWallets.count, 1) // Preserved recovery metadata, not product UI.
            model.select(archived.id); XCTAssertEqual(model.selectedID, current.id)
        }
        let saved = try JSONSerialization.jsonObject(with: XCTUnwrap(prefs.data(forKey: "mainnet.wallet-catalog.v1"))) as! [String: Any]
        XCTAssertEqual((saved["wallets"] as! [Any]).count, 1)
        XCTAssertEqual((saved["hiddenArchives"] as! [Any]).count, 1)
        XCTAssertTrue(store.data == original); XCTAssertEqual(store.deleted, 0)
    }
    @MainActor func testLegacyOnlyMigrationNeverReintroducesVisiblePreviewRecord() throws {
        let (prefs, suite) = preferences(); defer { prefs.removePersistentDomain(forName: suite) }
        let record = WalletRecord(try MassaTestAccount().publicAccount)
        let data = try JSONEncoder().encode(record); prefs.set(data, forKey: LegacyWalletMigration.singleRecordKey)
        for _ in 0..<2 {
            let model = WalletManager(defaults: prefs,
                stores: { _ in XCTFail("No current key access expected"); return ResetStore() },
                legacyStores: { _ in XCTFail("No archive key access expected"); return ResetStore() })
            XCTAssertTrue(model.wallets.isEmpty); XCTAssertTrue(model.activeWallets.isEmpty); XCTAssertNil(model.selectedID)
            XCTAssertEqual(model.archivedWallets.count, 1)
            XCTAssertEqual(prefs.data(forKey: LegacyWalletMigration.singleRecordKey), data)
        }
    }
    func testLogoutLabelAndConfirmationAreLocalizedIncludingExactRussianAction() throws {
        XCTAssertEqual(WalletLogoutText.action, "Log out of wallet")
        let path = try XCTUnwrap(Bundle.main.path(forResource: "ru", ofType: "lproj")), bundle = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(bundle.localizedString(forKey: WalletLogoutText.action, value: nil, table: nil), "Выйти из кошелька")
        for language in AppLanguage.allCases {
            let bundle = try XCTUnwrap(Bundle(path: XCTUnwrap(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"))))
            for key in [WalletLogoutText.action, WalletLogoutText.confirmationTitle, WalletLogoutText.confirmationAction, WalletLogoutText.incompleteTitle] {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "MISSING", table: nil), "MISSING")
            }
        }
    }
}
