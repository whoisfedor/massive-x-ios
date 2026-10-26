import XCTest
import LocalAuthentication
import Security
@testable import MassiveX

@MainActor private final class RemovalAuth: WalletAuthenticating {
    enum Mode { case success, deny, cancel, hold }
    var mode: Mode = .success
    var calls = 0
    var pending: CheckedContinuation<LAContext, any Error>?
    func authorize(reason: String) async throws -> LAContext {
        calls += 1
        switch mode {
        case .success: return LAContext()
        case .deny: throw OnboardingError.authentication
        case .cancel: throw OnboardingError.cancelled
        case .hold: return try await withCheckedThrowingContinuation { pending = $0 }
        }
    }
    func resume() { let continuation = pending; pending = nil; continuation?.resume(returning: LAContext()) }
    func cancel() { let continuation = pending; pending = nil; continuation?.resume(throwing: OnboardingError.cancelled) }
}
@MainActor private final class RemovalStore: TestAccountSecretStore {
    var bytes: Data?
    var deletes = 0
    var loads = 0
    var fail = false
    var afterDelete: (() -> Void)?
    func saveNew(_ seed: Data) throws { guard bytes == nil else { throw TestAccountStorageError.keychain(errSecDuplicateItem) }; bytes = seed }
    func load(context: LAContext?) throws -> Data? { loads += 1; return bytes }
    func delete() throws {
        if fail { throw TestAccountStorageError.keychain(errSecNotAvailable) }
        deletes += 1; bytes = nil; afterDelete?()
    }
}
@MainActor private final class RemovalStores {
    var values: [String: RemovalStore] = [:]
    var requested: Set<String> = []
    func store(_ id: String) -> RemovalStore {
        requested.insert(id)
        if let value = values[id] { return value }
        let value = RemovalStore(); values[id] = value; return value
    }
    var deletions: Int { values.values.reduce(0) { $0 + $1.deletes } }
}
private struct RemovalReadOnlyMock: MainnetReading {
    func status() async throws -> MainnetStatus { throw MainnetRPCError.offline }
    func balance(for address: String) async throws -> MainnetBalance { MainnetBalance(address: address, finalBalance: "2", candidateBalance: "2") }
}
@MainActor private final class RemovalClock { var now: TimeInterval = 100 }
@MainActor private final class RemovalFixture {
    let suite = "s01.disposable." + UUID().uuidString
    let defaults: UserDefaults
    let auth = RemovalAuth(), stores = RemovalStores(), clock = RemovalClock()
    let foreign = RemovalStore()
    let manager: WalletManager
    var backups: [String: String] = [:] // Disposable in-memory test inputs only; never printed or persisted.
    var owned: [String] = []
    var watch = ""
    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set("fr", forKey: "app.language"); defaults.set("JPY", forKey: "fiatCurrency")
        defaults.set("orange", forKey: "accentPalette"); defaults.set("Dark", forKey: "appearance")
        defaults.set(true, forKey: "balance-notifications.enabled")
        let archive = WalletRecord(try MassaTestAccount().publicAccount)
        defaults.set(try JSONEncoder().encode(archive), forKey: LegacyWalletMigration.singleRecordKey)
        foreign.bytes = Data(repeating: 9, count: 32)
        let registry = stores, authentication = auth, clock = self.clock, foreign = self.foreign
        manager = WalletManager(defaults: defaults, stores: { registry.store($0) },
            legacyStores: { _ in XCTFail("Legacy storage must not be accessed"); return foreign },
            authentication: { authentication }, client: RemovalReadOnlyMock(), balanceChanged: { _, _ in },
            removalClock: { clock.now }, walletsRemoved: { _ in })
        manager.removalPrivacy(active: true, captured: false)
    }
    func addWallets() async throws {
        for name in ["Disposable One", "Disposable Two"] {
            let added = await manager.addOwned(name: name, active: true, captured: false); XCTAssertTrue(added)
            let id = try XCTUnwrap(manager.selectedID), bytes = try XCTUnwrap(stores.values[id]?.bytes)
            owned.append(id); backups[id] = try MassaTestAccount(seed: bytes).testPrivateKeyEncoding()
        }
        XCTAssertTrue(manager.addWatchOnly(address: try MassaTestAccount().publicAccount.address, name: "Disposable Watch"))
        watch = try XCTUnwrap(manager.selectedID)
    }
    func reviewedPlan() throws -> WalletRemovalPlan {
        manager.select(owned[0])
        let plan = try XCTUnwrap(manager.beginRemovalReview())
        return plan
    }
    func cleanup() { manager.cancelRemovalReview(); backups.removeAll(); defaults.removePersistentDomain(forName: suite) }
}

/// No real Keychain, operator material, live transport or physical deletion is used.
@MainActor final class WalletRemovalSecurityTests: XCTestCase {
    private func waiting(_ auth: RemovalAuth) async {
        for _ in 0..<1000 { if auth.pending != nil { return }; await Task.yield() }
        XCTFail("Expected suspended mock authentication")
    }
    func testTwoOwnedWalletLogoutRemovesOnlySelectedAndPreservesOtherKeysPreferencesArchive() async throws {
        let f = try RemovalFixture(); defer { f.cleanup() }; try await f.addWallets()
        let other = f.stores.values[f.owned[1]]!, bytes = other.bytes
        let plan = try f.reviewedPlan(); XCTAssertEqual(plan.wallets.map(\.id), [f.owned[0]])
        let result = await f.manager.removeCurrentWallets(plan, acknowledged: true)
        XCTAssertTrue(result); XCTAssertEqual(f.stores.deletions, 1); XCTAssertTrue(other.bytes == bytes)
        XCTAssertEqual(Set(f.manager.activeWallets.map(\.id)), [f.owned[1],f.watch]); XCTAssertEqual(f.manager.selectedID, f.owned[1])
        XCTAssertEqual(f.foreign.deletes, 0); XCTAssertEqual(f.manager.archivedWallets.count, 1)
        XCTAssertEqual(f.defaults.string(forKey: "fiatCurrency"), "JPY"); XCTAssertEqual(f.defaults.string(forKey: "accentPalette"), "orange")
        let restarted = WalletManager(defaults: f.defaults, stores: { f.stores.store($0) }, authentication: { f.auth }, walletsRemoved: { _ in })
        XCTAssertEqual(restarted.activeWallets.count, 2); XCTAssertEqual(restarted.selectedID, f.owned[1])
    }
    func testUncheckedAttestationCannotRemoveAndDismissalInvalidatesReview() async throws {
        let f = try RemovalFixture(); defer { f.cleanup() }; try await f.addWallets()
        f.manager.select(f.owned[0]); let plan = try XCTUnwrap(f.manager.beginRemovalReview()), calls = f.auth.calls
        let unchecked = await f.manager.removeCurrentWallets(plan)
        XCTAssertFalse(unchecked); XCTAssertEqual(f.stores.deletions, 0); XCTAssertEqual(f.auth.calls, calls)
        f.manager.cancelRemovalReview()
        let stale = await f.manager.removeCurrentWallets(plan, acknowledged: true)
        XCTAssertFalse(stale); XCTAssertEqual(f.stores.deletions, 0)
        XCTAssertNotEqual(f.manager.beginRemovalReview()?.id, plan.id)
    }
    func testCancelDenyAndCancelledReviewDeleteNothing() async throws {
        for mode in [RemovalAuth.Mode.cancel, .deny] {
            let f = try RemovalFixture(); defer { f.cleanup() }; try await f.addWallets()
            let plan = try f.reviewedPlan(); f.auth.mode = mode
            let result = await f.manager.removeCurrentWallets(plan, acknowledged: true)
            XCTAssertFalse(result); XCTAssertEqual(f.stores.deletions, 0); XCTAssertNil(f.manager.removalPlan)
        }
        let f = try RemovalFixture(); defer { f.cleanup() }; try await f.addWallets()
        let plan = try f.reviewedPlan(); f.manager.cancelRemovalReview()
        let result = await f.manager.removeCurrentWallets(plan, acknowledged: true); XCTAssertFalse(result); XCTAssertEqual(f.stores.deletions, 0)
    }
    func testSelectionRenameInsertionBackgroundCaptureExpiryAndCancellationInvalidateAuthorization() async throws {
        for mutation in 0..<8 {
            let f = try RemovalFixture(); defer { f.cleanup() }; try await f.addWallets()
            let plan = try f.reviewedPlan(); f.auth.mode = .hold
            let task = Task { await f.manager.removeCurrentWallets(plan, acknowledged: true) }; await waiting(f.auth)
            switch mutation {
            case 0: f.manager.select(f.owned[1])
            case 1: f.manager.rename(f.owned[0], name: "Renamed")
            case 2: _ = f.manager.addWatchOnly(address: try MassaTestAccount().publicAccount.address, name: "Extra")
            case 3: f.manager.removalPrivacy(active: false, captured: false, background: true)
            case 4: f.manager.removalPrivacy(active: false, captured: true)
            case 5: f.clock.now += 31
            case 6: f.clock.now -= 1
            default: task.cancel()
            }
            f.auth.resume(); let result = await task.value
            XCTAssertFalse(result); XCTAssertEqual(f.stores.deletions, 0)
        }
    }
    func testDeleteFailureRetainsExactWalletAndOtherKeysThenRequiresFreshReview() async throws {
        let f = try RemovalFixture(); defer { f.cleanup() }; try await f.addWallets()
        let plan = try f.reviewedPlan(); f.stores.values[f.owned[0]]?.fail = true
        let result = await f.manager.removeCurrentWallets(plan, acknowledged: true)
        XCTAssertFalse(result); XCTAssertEqual(f.manager.removalFailure, .incomplete)
        XCTAssertEqual(f.manager.activeWallets.count, 3); XCTAssertNotNil(f.stores.values[f.owned[0]]?.bytes)
        XCTAssertNotNil(f.stores.values[f.owned[1]]?.bytes); XCTAssertEqual(f.stores.deletions, 0)
        f.stores.values[f.owned[0]]?.fail = false
        let old = await f.manager.removeCurrentWallets(plan, acknowledged: true); XCTAssertFalse(old)
        let next = try f.reviewedPlan(); let retried = await f.manager.removeCurrentWallets(next, acknowledged: true)
        XCTAssertTrue(retried); XCTAssertEqual(f.stores.deletions, 1)
    }
    func testLastWalletReturnsToOnboardingAndWatchOnlyRemovalDoesNotAccessKeyStore() async throws {
        let f = try RemovalFixture(); defer { f.cleanup() }
        let added = await f.manager.addOwned(active: true, captured: false); XCTAssertTrue(added)
        let plan = try XCTUnwrap(f.manager.beginRemovalReview())
        let result = await f.manager.removeCurrentWallets(plan, acknowledged: true); XCTAssertTrue(result)
        XCTAssertNil(f.manager.selectedID); XCTAssertTrue(f.manager.activeWallets.isEmpty)
        XCTAssertTrue(f.manager.addWatchOnly(address: try MassaTestAccount().publicAccount.address, name: "Watch"))
        let watchPlan = try XCTUnwrap(f.manager.beginRemovalReview()), requested = f.stores.requested
        let removedWatch = await f.manager.removeCurrentWallets(watchPlan, acknowledged: true)
        XCTAssertTrue(removedWatch); XCTAssertTrue(f.manager.activeWallets.isEmpty)
        XCTAssertEqual(f.stores.requested, requested); XCTAssertEqual(f.stores.deletions, 1)
    }
    func testConcurrentDuplicateLogoutCannotConsumeAuthorizationTwice() async throws {
        let f = try RemovalFixture(); defer { f.cleanup() }; try await f.addWallets()
        let plan = try f.reviewedPlan(); f.auth.mode = .hold
        let first = Task { await f.manager.removeCurrentWallets(plan, acknowledged: true) }; await waiting(f.auth)
        let second = await f.manager.removeCurrentWallets(plan, acknowledged: true); XCTAssertFalse(second)
        f.auth.resume(); let result = await first.value; XCTAssertTrue(result); XCTAssertEqual(f.stores.deletions, 1)
    }
}

private struct RemovalNeverNetwork: TransferNetworking {
    func snapshot(source: String, recipient: String) async throws -> SendSnapshot { XCTFail("No network is allowed in removal tests"); throw SendFailure.network }
    func submit(_ draft: ReviewedTransfer, signature: String) async throws -> String { XCTFail("No submission is allowed in removal tests"); throw SendFailure.network }
    func lookup(operationID: String) async throws -> SubmissionState { XCTFail("No lookup is allowed in removal tests"); throw SendFailure.network }
}
extension WalletRemovalSecurityTests {
    func testPendingJournalAndUnknownSourceLockSurviveRemovalAndReimport() async throws {
        let f = try RemovalFixture(); defer { f.cleanup() }; try await f.addWallets()
        let wallet = try SendWallet(XCTUnwrap(f.manager.activeWallets.first { $0.id == f.owned[0] }))
        let input = try XCTUnwrap(f.backups[f.owned[0]])
        let snapshot = SendSnapshot(fetched: Date(), chainID: 77658377, period: 100, validity: 10, fee: MASAmount(nano: 1), finalBalance: MASAmount(nano: 2_000_000_000), candidateBalance: MASAmount(nano: 2_000_000_000), recipientFinal: MASAmount(nano: 1), recipientCandidate: MASAmount(nano: 1))
        let draft = try ReviewedTransfer.make(wallet: wallet, recipient: f.manager.activeWallets[1].address, amount: "1", snapshot: snapshot, now: Date())
        let directory = FileManager.default.temporaryDirectory.appending(path: "s01-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "pending.json"), journal = FileTransferJournal(url: url)
        try journal.write([PendingTransfer(draft: draft, state: .outcomeUnknown)])
        let before = try Data(contentsOf: url), plan = try f.reviewedPlan()
        let removed = await f.manager.removeCurrentWallets(plan, acknowledged: true); XCTAssertTrue(removed)
        XCTAssertEqual(try Data(contentsOf: url), before)
        let reimported = await f.manager.addOwned(privateKey: input, active: true, captured: false); XCTAssertTrue(reimported)
        let restored = try SendWallet(XCTUnwrap(f.manager.selected))
        let coordinator = SendCoordinator(network: RemovalNeverNetwork(), journal: journal)
        XCTAssertEqual(coordinator.unresolved(restored)?.state, .outcomeUnknown)
        XCTAssertEqual(coordinator.unresolved(restored)?.draft.operationID, draft.operationID)
    }
}

extension WalletRemovalSecurityTests {
    func testSecondSelectedWalletIsTheOnlyDeletionTarget() async throws {
        let f = try RemovalFixture(); defer { f.cleanup() }; try await f.addWallets()
        f.manager.select(f.owned[1])
        let plan = try XCTUnwrap(f.manager.beginRemovalReview())
        XCTAssertEqual(plan.owned.map(\.id), [f.owned[1]])
        let removed = await f.manager.removeCurrentWallets(plan, acknowledged: true)
        XCTAssertTrue(removed); XCTAssertNotNil(f.stores.values[f.owned[0]]?.bytes); XCTAssertNil(f.stores.values[f.owned[1]]?.bytes)
        XCTAssertEqual(f.stores.values[f.owned[0]]?.deletes, 0); XCTAssertEqual(f.manager.selectedID, f.owned[0])
    }
}

extension WalletRemovalSecurityTests {
    func testOptionalNamesAcrossCreationAndWatchOnlyAllowDuplicatesWithoutKeyInjection() async throws {
        let f = try RemovalFixture(); defer { f.cleanup() }
        for input in ["", "   ", "  Named  "] {
            let added = await f.manager.addOwned(name: input, active: true, captured: false)
            XCTAssertTrue(added); XCTAssertEqual(f.manager.selected?.name, input.trimmingCharacters(in: .whitespaces).isEmpty ? "Wallet" : "Named")
        }
        let count = f.stores.values.count
        for input in ["", " ", " Named "] {
            XCTAssertTrue(f.manager.addWatchOnly(address: try MassaTestAccount().publicAccount.address, name: input))
            XCTAssertEqual(f.manager.selected?.kind, .watchOnly)
            XCTAssertEqual(f.manager.selected?.name, input.trimmingCharacters(in: .whitespaces).isEmpty ? "Wallet" : "Named")
            XCTAssertNil(f.manager.selected?.publicKey); XCTAssertNil(f.manager.backup)
            XCTAssertEqual(f.stores.values.count, count)
        }
        XCTAssertFalse(f.manager.addWatchOnly(address: "AUbad", name: ""))
        let before = f.manager.activeWallets.count; f.auth.mode = .cancel
        let cancelled = await f.manager.addOwned(name: "", active: true, captured: false)
        XCTAssertFalse(cancelled); XCTAssertEqual(f.manager.activeWallets.count, before)
    }
}

extension WalletRemovalSecurityTests {
    @MainActor func testSettingsLogoutLabelIncludesSelectedNameInAllSixLanguages() {
        let previous = UserDefaults.standard.object(forKey: "app.language")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "app.language") }
            else { UserDefaults.standard.removeObject(forKey: "app.language") }
        }
        for language in AppLanguage.allCases {
            UserDefaults.standard.set(language.rawValue, forKey: "app.language")
            let format = localized(WalletLogoutText.namedAction, language: language)
            XCTAssertNotEqual(format, "MISSING")
            XCTAssertEqual(format.components(separatedBy: "%@").count, 2)
            for name in ["Savings", "Primary", "Кошелёк %@ 100%", "钱包"] {
                let text = WalletLogoutText.settingsAction(walletName: name)
                XCTAssertTrue(text.contains(name)); XCTAssertNotEqual(text, L(WalletLogoutText.action))
                if language == .english { XCTAssertEqual(text, "Log out of wallet \"" + name + "\"") }
                if language == .russian { XCTAssertEqual(text, "Выйти из кошелька \"" + name + "\"") }
            }
            XCTAssertEqual(WalletLogoutText.settingsAction(walletName: nil), L(WalletLogoutText.action))
        }
    }
}
