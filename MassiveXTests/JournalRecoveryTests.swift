import XCTest
@testable import MassiveX

@MainActor private final class FaultJournal: TransferJournal {
    var records: [PendingTransfer] = []
    var readError: (any Error)?
    var writeError: (any Error)?
    func read() throws -> [PendingTransfer] { if let readError { throw readError }; return records }
    func write(_ records: [PendingTransfer]) throws { if let writeError { throw writeError }; self.records = records }
}
private actor P1Network: TransferNetworking {
    var snapshots = 0, submissions = 0
    func snapshot(source: String, recipient: String) async throws -> SendSnapshot { snapshots += 1; throw SendFailure.network }
    func submit(_ draft: ReviewedTransfer, signature: String) async throws -> String { submissions += 1; throw SendFailure.network }
    func lookup(operationID: String) async throws -> SubmissionState { .outcomeUnknown }
}
@MainActor final class JournalRecoveryTests: XCTestCase {
    private func wallet(_ index: UInt64 = 1) throws -> SendWallet {
        var raw = Data(repeating: 42, count: 32), index = index.bigEndian
        withUnsafeBytes(of: &index) { raw.replaceSubrange(0..<8, with: $0) }
        let identity = try MassaPublicAccount(rawPublicKey: raw)
        return try SendWallet(ManagedWallet(id: UUID().uuidString, name: "Disposable public fixture", address: identity.address, publicKey: identity.publicKey, kind: .owned, network: "Mainnet", backupAcknowledged: false))
    }
    private func record(_ index: UInt64 = 1, state: SubmissionState = .outcomeUnknown, source: SendWallet? = nil) throws -> PendingTransfer {
        let source = try source ?? wallet(index), recipient = try wallet(20000).address, now = Date()
        let snapshot = SendSnapshot(fetched: now, chainID: 77658377, period: 100 + index, validity: 10, fee: MASAmount(nano: 1), finalBalance: MASAmount(nano: 10), candidateBalance: MASAmount(nano: 10), recipientFinal: MASAmount(nano: 1), recipientCandidate: MASAmount(nano: 1))
        return try PendingTransfer(draft: ReviewedTransfer.make(wallet: source, recipient: recipient, amount: "0.000000001", snapshot: snapshot, now: now), state: state)
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appending(path: "p1-" + UUID().uuidString) }
    func testTransientReadAndWriteFaultReloadRetainsLocksAndNeverSubmits() async throws {
        for writing in [false, true] {
            let journal = FaultJournal(), record = try record(), network = P1Network()
            journal.records = [record]
            if writing { journal.writeError = TransferJournalError.unavailable } else { journal.readError = TransferJournalError.unavailable }
            let coordinator = SendCoordinator(network: network, journal: journal); coordinator.select(record.draft.wallet)
            XCTAssertEqual(coordinator.journalIssue, .unavailable)
            journal.readError = nil; journal.writeError = nil
            XCTAssertTrue(coordinator.reloadJournal()); XCTAssertNil(coordinator.journalIssue)
            XCTAssertEqual(coordinator.unresolved(record.draft.wallet)?.draft.operationID, record.draft.operationID)
            await coordinator.prepare(wallet: record.draft.wallet, recipient: record.draft.recipient, amount: "0.000000001")
            XCTAssertEqual(coordinator.failure, .duplicate)
            let counts = await (network.snapshots, network.submissions); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        }
    }
    func testMissingAnchoredOrCorruptJournalCannotBecomeEmptyOnReload() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "pending.json"), journal = FileTransferJournal(url: url), record = try record()
        try journal.write([record]); let original = try Data(contentsOf: url)
        let coordinator = SendCoordinator(network: P1Network(), journal: journal)
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(coordinator.reloadJournal()); XCTAssertEqual(coordinator.journalIssue, .missing)
        XCTAssertEqual(coordinator.pending.count, 1)
        try Data("bad".utf8).write(to: url)
        XCTAssertFalse(coordinator.reloadJournal()); XCTAssertEqual(coordinator.journalIssue, .corrupt)
        XCTAssertEqual(try Data(contentsOf: url), Data("bad".utf8))
        try original.write(to: url)
        XCTAssertTrue(coordinator.reloadJournal()); XCTAssertEqual(coordinator.pending.count, 1)
        let restart = SendCoordinator(network: P1Network(), journal: journal)
        XCTAssertNotNil(restart.unresolved(record.draft.wallet))
    }
    func testTruncatedValidEmptySnapshotDoesNotEraseKnownInMemoryOperations() throws {
        let journal = FaultJournal(); journal.records = [try record()]
        let coordinator = SendCoordinator(network: P1Network(), journal: journal)
        journal.records = []
        XCTAssertFalse(coordinator.reloadJournal()); XCTAssertEqual(coordinator.journalIssue, .inconsistent)
        XCTAssertEqual(coordinator.pending.count, 1)
    }
    func testInterruptedReplacementPreservesOriginalAndReloadCanRecover() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "pending.json"), record = try record(), good = FileTransferJournal(url: url)
        try good.write([record]); let original = try Data(contentsOf: url)
        for protectedURL in [url, url.appendingPathExtension("initialized")] {
            let protection = try FileManager.default.attributesOfItem(atPath: protectedURL.path)[.protectionKey]
            let resolved = protection as? FileProtectionType ?? (protection as? String).map { FileProtectionType(rawValue: $0) }
            #if targetEnvironment(simulator)
            // This runtime may omit Data Protection attributes. Physical protection is a separate device gate.
            XCTAssertTrue(resolved == nil || resolved == .complete)
            #else
            XCTAssertEqual(resolved, .complete)
            #endif
        }
        let failing = FileTransferJournal(url: url, replace: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try failing.write([])); XCTAssertEqual(try Data(contentsOf: url), original)
        let coordinator = SendCoordinator(network: P1Network(), journal: failing)
        XCTAssertNotNil(coordinator.journalIssue)
        XCTAssertEqual(try good.read().first?.draft.operationID, record.draft.operationID)
    }
    func testCapacity9999And10000Accept10001RejectWithoutReplacing() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = FileTransferJournal(url: directory.appending(path: "pending.json")), source = try wallet()
        var records = try (1...9999).map { try record(UInt64($0), state: .finalized, source: source) }
        try journal.write(records); XCTAssertEqual(try journal.read().count, 9999)
        records.append(try record(10000, state: .failed, source: source))
        try journal.write(records); XCTAssertEqual(try journal.read().count, 10000)
        let original = try Data(contentsOf: directory.appending(path: "pending.json"))
        records.append(try record(10001, state: .finalized, source: source))
        XCTAssertThrowsError(try journal.write(records)) { XCTAssertEqual($0 as? TransferJournalError, .capacity) }
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "pending.json")), original)
        XCTAssertEqual(try journal.read().count, 10000)
    }
    func testAllUnresolvedManyWalletCapacityBlocksBeforeNetworkAndPreservesEveryLock() async throws {
        let journal = FaultJournal(); journal.records = try (1...10000).map { try record(UInt64($0)) }
        let network = P1Network(), coordinator = SendCoordinator(network: network, journal: journal), newWallet = try wallet(30000)
        XCTAssertNil(coordinator.journalIssue); XCTAssertEqual(coordinator.pending.count, 10000)
        coordinator.select(newWallet)
        await coordinator.prepare(wallet: newWallet, recipient: try wallet(20000).address, amount: "0.000000001")
        XCTAssertEqual(coordinator.failure, .journalCapacity)
        let counts = await (network.snapshots, network.submissions); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        let existing = try XCTUnwrap(coordinator.pending.first)
        await coordinator.reconcile(existing)
        XCTAssertEqual(coordinator.pending.count, 10000); XCTAssertNotNil(coordinator.unresolved(existing.draft.wallet))
        let restart = SendCoordinator(network: network, journal: journal)
        XCTAssertEqual(restart.pending.filter { $0.state.unresolved }.count, 10000)
    }
    func testLegacyOversizedJournalIsPreservedNotCompactedOrOverwritten() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = try wallet(), values = try (1...10001).map { try record(UInt64($0), state: .finalized, source: source) }
        let data = try JSONEncoder().encode(values), url = directory.appending(path: "pending.json")
        try data.write(to: url)
        let journal = FileTransferJournal(url: url), coordinator = SendCoordinator(network: P1Network(), journal: journal)
        XCTAssertEqual(coordinator.journalIssue, .capacity); XCTAssertFalse(coordinator.reloadJournal())
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
