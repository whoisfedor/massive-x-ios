import XCTest
import LocalAuthentication
@testable import MassiveX

@MainActor private final class TrustJournal: TransferJournal {
    let installationID: UUID? = TransferTestContinuity.id
    var records: [PendingTransfer] = []
    var fails = false
    func read() throws -> [PendingTransfer] { records }
    func write(_ records: [PendingTransfer]) throws { if fails { throw TransferJournalError.unavailable }; self.records = records }
}
private actor HostileStatus: TransferNetworking {
    var reported: SubmissionState
    var writes = 0, reads = 0
    var bypass = false
    init(_ state: SubmissionState) { reported = state }
    func configure(_ state: SubmissionState, bypass: Bool = false) { reported = state; self.bypass = bypass }
    func snapshot(source: String, recipient: String) async throws -> SendSnapshot { reads += 1; throw SendFailure.network }
    func submit(_ draft: ReviewedTransfer, signature: String) async throws -> String { writes += 1; XCTFail("Reconciliation must never submit"); throw SendFailure.network }
    func lookup(operationID: String) async throws -> SubmissionState { reported }
    func reconciliation(for draft: ReviewedTransfer) async throws -> ReconciliationAssessment {
        if bypass { return ReconciliationAssessment(state: reported, reason: .observed, checkedAt: Date(), reportedFinalPeriod: 999) }
        return .combine(reported, reported, finalPeriod: 999, expiry: draft.expiry)
    }
}
@MainActor private final class ContinuityStore: TestAccountSecretStore {
    var data: Data?
    func saveNew(_ seed: Data) throws { data = seed }
    func load(context: LAContext?) throws -> Data? { data }
    func delete() throws { XCTFail("No key deletion in these tests"); throw SendFailure.response }
}
@MainActor private struct ContinuityAuth: WalletAuthenticating {
    func authorize(reason: String) async throws -> LAContext { LAContext() }
    func cancel() {}
}
@MainActor final class TransferTrustRecoveryTests: XCTestCase {
    private func wallet(_ raw: UInt8 = 61, origin: UUID? = TransferTestContinuity.id) throws -> SendWallet {
        let identity = try MassaPublicAccount(rawPublicKey: Data(repeating: raw, count: 32))
        return try SendWallet(ManagedWallet(id: UUID().uuidString, name: "Public fixture", address: identity.address, publicKey: identity.publicKey, kind: .owned, network: "Mainnet", backupAcknowledged: false, creationJournalID: origin))
    }
    private func record(_ period: UInt64 = 100, state: SubmissionState = .outcomeUnknown, source: SendWallet? = nil) throws -> PendingTransfer {
        let wallet = try source ?? wallet(), now = Date()
        let snapshot = SendSnapshot(fetched: now, chainID: 77658377, period: period, validity: 10, fee: MASAmount(nano: 1), finalBalance: MASAmount(nano: 10), candidateBalance: MASAmount(nano: 10), recipientFinal: MASAmount(nano: 1), recipientCandidate: MASAmount(nano: 1))
        return try PendingTransfer(draft: ReviewedTransfer.make(wallet: wallet, recipient: wallet.address, amount: "0.000000001", snapshot: snapshot, now: now), state: state)
    }
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mx-trust-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory
    }
    func testConsistentlyForgedTerminalClaimsNeverUnlockEvenAfterRestart() async throws {
        for state in [SubmissionState.finalized, .failed] {
            let journal = TrustJournal(), original = try record(), network = HostileStatus(state)
            journal.records = [original]
            let send = SendCoordinator(network: network, journal: journal); send.select(original.draft.wallet)
            await send.reconcile(original)
            XCTAssertEqual(send.phase, .outcomeUnknown)
            XCTAssertEqual(send.pending.first?.assessment?.reportedState, state)
            XCTAssertNotNil(send.unresolved(original.draft.wallet))
            let restart = SendCoordinator(network: network, journal: journal); restart.select(original.draft.wallet)
            await restart.prepare(wallet: original.draft.wallet, recipient: original.draft.recipient, amount: "0.000000001")
            XCTAssertEqual(restart.failure, .duplicate)
            let writes = await network.writes; XCTAssertEqual(writes, 0)
        }
    }
    func testAdapterCannotBypassCoordinatorWithTerminalLabel() async throws {
        let journal = TrustJournal(), original = try record(), network = HostileStatus(.finalized)
        journal.records = [original]; await network.configure(.failed, bypass: true)
        let send = SendCoordinator(network: network, journal: journal)
        await send.reconcile(original)
        XCTAssertEqual(send.pending.first?.state, .outcomeUnknown)
        XCTAssertNotNil(send.unresolved(original.draft.wallet))
    }
    func testDifferentURLsOrClaimedOperatorsAreNotProofAndDisagreementStaysLocked() throws {
        let original = try record(), now = Date()
        for operators in [["one-backend", "one-backend"], ["operator-a", "operator-b"]] {
            let observations = zip(["https://a.invalid/rpc", "https://b.invalid/rpc"], operators).map {
                NodeObservation(operationID: original.draft.operationID, chainID: 77658377, endpoint: $0.0, operatorID: $0.1, nodeVersion: "MAIN.5.0", reportedState: .finalized, observedAt: now, reportedFinalPeriod: 200)
            }
            let matching = ReconciliationAssessment.combine(.finalized, .finalized, finalPeriod: 200, expiry: 109, now: now, operationID: original.draft.operationID, observations: observations)
            XCTAssertEqual(matching.state, .outcomeUnknown); XCTAssertEqual(matching.reason, .uncorroboratedTerminal)
            let conflict = ReconciliationAssessment.combine(.finalized, .failed, finalPeriod: 200, expiry: 109, now: now, operationID: original.draft.operationID, observations: observations)
            XCTAssertEqual(conflict.reason, .conflictingObservations); XCTAssertEqual(conflict.state, .outcomeUnknown)
        }
    }
    func testWrongIDChainVersionAndStaleProvenanceCannotBecomeDecisionEvidence() throws {
        let original = try record(), now = Date()
        for scenario in 0..<4 {
            let observation = NodeObservation(operationID: scenario == 0 ? "wrong" : original.draft.operationID,
                chainID: scenario == 1 ? 1 : 77658377, endpoint: "https://a.invalid", operatorID: "unverified",
                nodeVersion: scenario == 2 ? "other" : "MAIN.5.0", reportedState: .finalized,
                observedAt: now.addingTimeInterval(scenario == 3 ? -31 : 0), reportedFinalPeriod: 200)
            let result = ReconciliationAssessment.combine(.finalized, .finalized, finalPeriod: 200, expiry: 109, now: now, operationID: original.draft.operationID, observations: [observation])
            XCTAssertEqual(result.reason, .invalidEvidence); XCTAssertEqual(result.state, .outcomeUnknown)
        }
    }
    func testPreviouslyReportedFinalThenConflictingOrPrunedNeverReleasesLock() async throws {
        let journal = TrustJournal(), original = try record(state: .finalized), network = HostileStatus(.failed)
        var attempted = original; attempted.tracking = .localSubmission
        journal.records = [attempted]
        let send = SendCoordinator(network: network, journal: journal)
        XCTAssertEqual(send.pending.first?.assessment?.reportedState, .finalized)
        await send.reconcile(try XCTUnwrap(send.pending.first))
        XCTAssertEqual(send.pending.first?.state, .outcomeUnknown)
        XCTAssertEqual(send.pending.first?.assessment?.reason, .conflictingObservations)
        await network.configure(.outcomeUnknown); await send.reconcile(try XCTUnwrap(send.pending.first))
        XCTAssertNotNil(send.unresolved(original.draft.wallet)); XCTAssertEqual(send.pending.first?.draft, original.draft)
        XCTAssertEqual(send.pending.first?.assessment?.reason, .conflictingObservations)
    }
    func testVersionedMigrationPreservesEveryOriginalIntentAndReportedState() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try wallet(), originals = try [record(100, state: .finalized, source: source), record(101, state: .failed, source: source)]
        let url = directory.appending(path: "journal.json"); try JSONEncoder().encode(originals).write(to: url)
        let journal = FileTransferJournal(url: url), send = SendCoordinator(network: HostileStatus(.outcomeUnknown), journal: journal)
        XCTAssertNil(send.journalIssue); XCTAssertEqual(send.pending.map(\.draft), originals.map(\.draft))
        XCTAssertEqual(send.pending.map { $0.assessment?.reportedState }, [.finalized, .failed])
        XCTAssertTrue(send.pending.allSatisfy { $0.state == .outcomeUnknown && $0.tracking == .localSubmission })
        XCTAssertNotNil(send.unresolved(source))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(object["version"] as? Int, 2)
        let identity = try XCTUnwrap(journal.installationID), restart = FileTransferJournal(url: url)
        XCTAssertEqual(try restart.read().count, 2); XCTAssertEqual(restart.installationID, identity)
    }
    func testUnknownVersionOrInterruptedMigrationPreservesOriginalBytes() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "journal.json"), original = try JSONEncoder().encode([record()])
        try original.write(to: url)
        let failing = FileTransferJournal(url: url, replace: { _, _ in throw TransferJournalError.unavailable })
        let send = SendCoordinator(network: HostileStatus(.outcomeUnknown), journal: failing)
        XCTAssertNotNil(send.journalIssue); XCTAssertEqual(try Data(contentsOf: url), original)
        let unknown = Data(#"{"version":999,"records":[]}"#.utf8); try unknown.write(to: url)
        let reload = SendCoordinator(network: HostileStatus(.outcomeUnknown), journal: FileTransferJournal(url: url))
        XCTAssertEqual(reload.journalIssue, .corrupt); XCTAssertEqual(try Data(contentsOf: url), unknown)
    }
    func testIntactJournalAndMissingMarkerRetainContinuityAndEveryLock() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "journal.json"), journal = FileTransferJournal(url: url, initialIdentity: TransferTestContinuity.id)
        try journal.write([record()]); let original = try Data(contentsOf: url)
        let clone = directory.appending(path: "without-marker.json"); try original.write(to: clone)
        let send = SendCoordinator(network: HostileStatus(.outcomeUnknown), journal: FileTransferJournal(url: clone))
        XCTAssertTrue(send.hasCreationBinding(try wallet())); XCTAssertEqual(send.pending.count, 1)
    }
    func testTotalArtifactLossIsNotCleanHistoryButDoesNotBanNewPaymentPreflight() async throws {
        // A second fresh directory models loss. The first journal is never deleted or changed.
        let oldDirectory = try temporary(), newDirectory = try temporary()
        defer { try? FileManager.default.removeItem(at: oldDirectory); try? FileManager.default.removeItem(at: newDirectory) }
        let oldURL = oldDirectory.appending(path: "journal.json"), old = FileTransferJournal(url: oldURL, initialIdentity: TransferTestContinuity.id)
        try old.write([record()]); let original = try Data(contentsOf: oldURL), network = HostileStatus(.outcomeUnknown)
        let fresh = SendCoordinator(network: network, journal: FileTransferJournal(url: newDirectory.appending(path: "journal.json")))
        for source in [try wallet(), try wallet(origin: nil)] {
            fresh.select(source); XCTAssertFalse(fresh.hasCreationBinding(source))
            await fresh.prepare(wallet: source, recipient: source.address, amount: "0.000000001")
            XCTAssertEqual(fresh.failure, .network); XCTAssertNil(fresh.review)
        }
        XCTAssertEqual(try Data(contentsOf: oldURL), original)
        let counts = await (network.reads, network.writes); XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 0)
    }
    func testKnownMissingAnchoredJournalStaysClosed() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "journal.json")
        try Data([1]).write(to: url.appendingPathExtension("initialized"))
        let send = SendCoordinator(network: HostileStatus(.outcomeUnknown), journal: FileTransferJournal(url: url))
        XCTAssertEqual(send.journalIssue, .missing); XCTAssertNil(send.journalIdentity)
    }
    func testPublicRestoreIsMergeOnlyAndRetainsKnownAmbiguityForReimportedIdentity() async throws {
        let journal = TrustJournal(), existing = try record(source: wallet(62)), original = try record(), imported = try wallet(origin: nil)
        journal.records = [existing]; let network = HostileStatus(.outcomeUnknown), send = SendCoordinator(network: network, journal: journal)
        let file = try PublicOperationFile.decode(PublicOperationFile(operations: [original.draft]).encoded(), for: imported)
        try send.restorePublicOperations(file, for: imported)
        XCTAssertEqual(send.pending.map(\.draft), [existing.draft, original.draft]); XCTAssertFalse(send.hasCreationBinding(imported))
        let restart = SendCoordinator(network: network, journal: journal); restart.select(imported)
        await restart.prepare(wallet: imported, recipient: imported.address, amount: "0.000000001")
        XCTAssertEqual(restart.failure, .duplicate); XCTAssertEqual(restart.pending.count, 2)
        try restart.restorePublicOperations(file, for: imported); XCTAssertEqual(restart.pending.count, 2)
        let writes = await network.writes; XCTAssertEqual(writes, 0)
    }
    func testPublicFileRejectsUnknownVersionWrongIdentityMalformedAndOversizedInput() throws {
        let original = try record(), file = PublicOperationFile(operations: [original.draft])
        let data = try file.encoded(); XCTAssertThrowsError(try PublicOperationFile.decode(data, for: wallet(63)))
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["version"] = 999
        XCTAssertThrowsError(try PublicOperationFile.decode(JSONSerialization.data(withJSONObject: object), for: original.draft.wallet))
        object["version"] = 1; object["chainID"] = 1
        XCTAssertThrowsError(try PublicOperationFile.decode(JSONSerialization.data(withJSONObject: object), for: original.draft.wallet))
        object["chainID"] = 77658377
        var operations = object["operations"] as! [[String: Any]]
        operations[0]["amount"] = ["nano": 2]; object["operations"] = operations
        XCTAssertThrowsError(try PublicOperationFile.decode(JSONSerialization.data(withJSONObject: object), for: original.draft.wallet))
        XCTAssertThrowsError(try PublicOperationFile.decode(Data("bad".utf8), for: original.draft.wallet))
        XCTAssertThrowsError(try PublicOperationFile.decode(Data(repeating: 32, count: PublicOperationFile.maximumBytes + 1), for: original.draft.wallet))
        XCTAssertThrowsError(try PublicOperationFile(operations: []).validate(for: original.draft.wallet))
        XCTAssertThrowsError(try PublicOperationFile(operations: [original.draft, original.draft]).validate(for: original.draft.wallet))
    }
    func testRestoreCannotExceedCapacityAndDiagnosticDescriptionsStayRedacted() throws {
        let journal = TrustJournal(), source = try wallet()
        journal.records = try (1...10000).map { try record(UInt64($0), source: source) }
        let send = SendCoordinator(network: HostileStatus(.outcomeUnknown), journal: journal)
        XCTAssertThrowsError(try send.restorePublicOperations(PublicOperationFile(operations: [try record(20000, source: source).draft]), for: source)) {
            XCTAssertEqual($0 as? SendFailure, .journalCapacity)
        }
        XCTAssertEqual(journal.records.count, 10000); XCTAssertEqual(send.pending.count, 10000)
        let value = try XCTUnwrap(send.pending.first)
        for text in [String(reflecting: value), String(reflecting: value.draft), String(reflecting: source)] {
            XCTAssertFalse(text.contains(source.address)); XCTAssertFalse(text.contains(source.publicKey))
            XCTAssertTrue(text.contains("<redacted>"))
        }
    }
    func testSameIDConflictingMetadataOrStorageFailureNeverReplacesKnownEvidence() throws {
        let journal = TrustJournal(), original = try record(); journal.records = [original]
        let send = SendCoordinator(network: HostileStatus(.outcomeUnknown), journal: journal)
        let persisted = journal.records
        XCTAssertEqual(persisted.first?.draft, original.draft); XCTAssertEqual(persisted.first?.state, original.state)
        XCTAssertEqual(persisted.first?.tracking, .localSubmission)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original.draft)) as! [String: Any]
        object["reviewedAt"] = 1
        let changed = try JSONDecoder().decode(ReviewedTransfer.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try send.restorePublicOperations(PublicOperationFile(operations: [changed]), for: original.draft.wallet))
        XCTAssertEqual(journal.records, persisted)
        journal.fails = true
        XCTAssertThrowsError(try send.restorePublicOperations(PublicOperationFile(operations: [try record(101).draft]), for: original.draft.wallet))
        XCTAssertEqual(journal.records, persisted); XCTAssertNotNil(send.journalIssue)
    }
    func testCreationMetadataIsRetainedAndImportDoesNotInheritGenerationMetadata() async throws {
        let suite = "mx-continuity-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var stores: [String: ContinuityStore] = [:]
        let manager = WalletManager(defaults: defaults, stores: { id in
            if let store = stores[id] { return store }; let store = ContinuityStore(); stores[id] = store; return store
        }, authentication: { ContinuityAuth() }, balanceChanged: { _, _ in }, walletsRemoved: { _ in })
        let created = await manager.addOwned(active: true, captured: false, creationJournalID: TransferTestContinuity.id)
        XCTAssertTrue(created); XCTAssertEqual(manager.selected?.creationJournalID, TransferTestContinuity.id)
        let disposable = MassaTestAccount()
        let imported = await manager.addOwned(privateKey: try disposable.backupPrivateKeyEncoding(), active: true, captured: false, creationJournalID: TransferTestContinuity.id)
        XCTAssertTrue(imported); XCTAssertNil(manager.selected?.creationJournalID)
        let restored = WalletManager(defaults: defaults, stores: { stores[$0]! }, authentication: { ContinuityAuth() })
        XCTAssertEqual(restored.wallets.count, 2); XCTAssertNil(restored.selected?.creationJournalID)
    }
}
