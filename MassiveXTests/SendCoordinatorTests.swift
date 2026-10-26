import XCTest
import LocalAuthentication
import Security
@testable import MassiveX

@MainActor private final class MemoryJournal: TransferJournal {
    let installationID: UUID? = TransferTestContinuity.id
    var records: [PendingTransfer] = []
    var fails = false
    var writes = 0
    func read() throws -> [PendingTransfer] { if fails { throw SendFailure.journal }; return records }
    func write(_ records: [PendingTransfer]) throws { if fails { throw SendFailure.journal }; writes += 1; self.records = records }
}
@MainActor private final class MockSigner: TransferSigning {
    let account: MassaTestAccount
    var cancelled = false, calls = 0, fail = false
    init(_ account: MassaTestAccount) { self.account = account }
    func sign(_ draft: ReviewedTransfer) async throws -> String {
        calls += 1
        if fail { throw SendFailure.cancelled }
        return try account.testSign(message: MassaOperationEncoding.canonical(content: draft.content, publicKey: draft.wallet.publicKey))
    }
    func cancel() { cancelled = true }
}
private actor MockNetwork: TransferNetworking {
    var submissions = 0, snapshots = 0, lookups = 0
    var holdLookup = false
    var lookupWaiter: CheckedContinuation<Void, Never>?
    func holdStatusRead() { holdLookup = true }
    func releaseStatusRead() { holdLookup = false; lookupWaiter?.resume(); lookupWaiter = nil }
    var timeout = false, mismatch = false, delay = false
    var result = SubmissionState.pending
    var fee: UInt64 = 10_000_000
    var stale = false
    var recipientNano: UInt64 = 1
    var period: UInt64 = 100
    func setPeriod(_ value: UInt64) { period = value }
    func configure(timeout: Bool = false, mismatch: Bool = false, delay: Bool = false, result: SubmissionState = .pending, fee: UInt64 = 10_000_000, stale: Bool = false) {
        self.timeout = timeout; self.mismatch = mismatch; self.delay = delay; self.result = result; self.fee = fee; self.stale = stale
    }
    func snapshot(source: String, recipient: String) async throws -> SendSnapshot {
        snapshots += 1
        if delay { try await Task.sleep(for: .milliseconds(30)) }
        return SendSnapshot(fetched: Date().addingTimeInterval(stale ? -60 : 0), chainID: 77658377, period: period, validity: 10,
            fee: MASAmount(nano: fee), finalBalance: MASAmount(nano: 10_000_000_000), candidateBalance: MASAmount(nano: 9_000_000_000),
            recipientFinal: MASAmount(nano: recipientNano), recipientCandidate: MASAmount(nano: recipientNano))
    }
    func setRecipientBalance(_ nano: UInt64) { recipientNano = nano }
    func submit(_ draft: ReviewedTransfer, signature: String) async throws -> String {
        submissions += 1
        if delay { try await Task.sleep(for: .milliseconds(50)) }
        if timeout { throw URLError(.timedOut) }
        return mismatch ? "wrong" : draft.operationID
    }
    func lookup(operationID: String) async throws -> SubmissionState {
        lookups += 1
        if holdLookup { await withCheckedContinuation { lookupWaiter = $0 } }
        return result
    }
}

@MainActor final class SendCoordinatorTests: XCTestCase {
    private func wallet(_ account: MassaTestAccount) throws -> SendWallet {
        let identity = try account.publicAccount
        return try SendWallet(ManagedWallet(id: UUID().uuidString, name: "Disposable", address: identity.address, publicKey: identity.publicKey, kind: .owned, network: "Mainnet", backupAcknowledged: true, creationJournalID: TransferTestContinuity.id))
    }
    private func setup() throws -> (SendCoordinator, MockNetwork, MemoryJournal, MockSigner, SendWallet, String) {
        let account = MassaTestAccount(), wallet = try wallet(account), network = MockNetwork(), journal = MemoryJournal()
        let coordinator = SendCoordinator(network: network, journal: journal)
        coordinator.select(wallet)
        return (coordinator, network, journal, MockSigner(account), wallet, try MassaTestAccount().publicAccount.address)
    }
    func testValidReviewSignatureSubmissionAndFinality() async throws {
        let (c,n,j,s,w,to) = try setup()
        await c.prepare(wallet: w, recipient: to, amount: "1.123456789")
        XCTAssertEqual(c.phase, .review)
        XCTAssertEqual(c.review?.total.text, "1.133456789")
        await c.confirm(approved: c.review, signer: s)
        XCTAssertEqual(c.phase, .pending); XCTAssertEqual(j.records.count, 1); XCTAssertGreaterThanOrEqual(j.writes, 2)
        let writes = await n.submissions; XCTAssertEqual(writes, 1)
        await n.configure(result: .finalized)
        await c.reconcile(try XCTUnwrap(j.records.first))
        XCTAssertEqual(c.phase, .outcomeUnknown); XCTAssertNotNil(c.unresolved(w))
    }
    func testStandardBuildSubmitsOnlyAfterReviewedAuthentication() async throws {
        let (_,n,j,s,w,to) = try setup(), c = SendCoordinator(network: n, journal: j)
        c.select(w); await c.prepare(wallet: w, recipient: to, amount: "1"); await c.confirm(approved: c.review, signer: s)
        let writes = await n.submissions
        XCTAssertEqual(s.calls, 1); XCTAssertEqual(writes, 1); XCTAssertEqual(c.phase, .pending)
    }
    func testWrongKeyAndCancelledAuthenticationNeverSubmit() async throws {
        for wrongKey in [false, true] {
            let (c,n,j,s,w,to) = try setup()
            await c.prepare(wallet: w, recipient: to, amount: "1")
            let signer = wrongKey ? MockSigner(MassaTestAccount()) : s; signer.fail = !wrongKey
            await c.confirm(approved: c.review, signer: signer)
            XCTAssertEqual(c.phase, .review); XCTAssertTrue(j.records.isEmpty)
            let writes = await n.submissions; XCTAssertEqual(writes, 0)
            XCTAssertEqual(c.message, wrongKey ? SendFailure.keyUnavailable.message : SendFailure.cancelled.message)
        }
    }
    func testChangedFeeAndStaleSnapshotInvalidateReview() async throws {
        for stale in [false, true] {
            let (c,n,j,s,w,to) = try setup()
            await c.prepare(wallet: w, recipient: to, amount: "1")
            await n.configure(fee: 20_000_000, stale: stale)
            await c.confirm(approved: c.review, signer: s)
            XCTAssertNil(c.review); XCTAssertEqual(s.calls, 0); XCTAssertTrue(j.records.isEmpty)
        }
    }
    func testExactValidationOverflowPrecisionAndRecipientPreflight() async throws {
        let (_,n,_,_,w,to) = try setup(), snap = try await n.snapshot(source: w.address, recipient: to)
        for value in ["0", "-1", "1e2", "1.0000000001", "18446744072.709551615", "9"] {
            XCTAssertThrowsError(try ReviewedTransfer.make(wallet: w, recipient: to, amount: value, snapshot: snap, now: Date()))
        }
        XCTAssertThrowsError(try ReviewedTransfer.make(wallet: w, recipient: "AUbad", amount: "1", snapshot: snap, now: Date()))
        let empty = SendSnapshot(fetched: Date(), chainID: snap.chainID, period: snap.period, validity: snap.validity, fee: snap.fee, finalBalance: snap.finalBalance, candidateBalance: snap.candidateBalance, recipientFinal: MASAmount(nano: 0), recipientCandidate: MASAmount(nano: 0))
        let zero = try ReviewedTransfer.make(wallet: w, recipient: to, amount: "1", snapshot: empty, now: Date())
        XCTAssertEqual(zero.recipientCredit?.minimum.text, "0.999")
        XCTAssertEqual(zero.total.text, "1.01")
        await n.configure(stale: true)
        let stale = try await n.snapshot(source: w.address, recipient: to)
        XCTAssertThrowsError(try ReviewedTransfer.make(wallet: w, recipient: to, amount: "1", snapshot: stale, now: Date()))
    }
    func testZeroOrAbsentRecipientCreationCostMinimumAndExactCredit() async throws {
        let (c,n,_,signer,w,to) = try setup()
        await n.setRecipientBalance(0)
        await c.prepare(wallet: w, recipient: to, amount: "0.000999999")
        XCTAssertEqual(c.failure, .creationMinimum); XCTAssertNil(c.review)
        await c.prepare(wallet: w, recipient: to, amount: "0.001")
        let minimum = try XCTUnwrap(c.review)
        XCTAssertEqual(minimum.recipientCredit?.minimum.nano, 0)
        XCTAssertEqual(minimum.recipientCredit?.maximum.nano, 1_000_000)
        XCTAssertEqual(minimum.total.nano, 11_000_000)
        await c.confirm(approved: minimum, signer: signer)
        XCTAssertEqual(c.phase, .pending)
        let writes = await n.submissions; XCTAssertEqual(writes, 1)
        XCTAssertEqual(try RecipientCredit.make(amount: MASAmount("1.123456789"), uncertain: true).minimum.text, "1.122456789")
        XCTAssertEqual(try RecipientCredit.make(amount: MASAmount(nano: 1), uncertain: false).minimum.nano, 1)
    }
    func testRecipientStateChangeRequiresNewReviewBeforeAuthentication() async throws {
        let (c,n,j,signer,w,to) = try setup()
        await c.prepare(wallet: w, recipient: to, amount: "1")
        await n.setRecipientBalance(0)
        await c.confirm(approved: c.review, signer: signer)
        XCTAssertEqual(c.failure, .changed); XCTAssertNil(c.review)
        XCTAssertEqual(signer.calls, 0); XCTAssertTrue(j.records.isEmpty)
    }
    func testLegacyPendingWithoutCreditStillLocksSourceAfterUpgrade() async throws {
        let (c,n,j,_,w,to) = try setup()
        await c.prepare(wallet: w, recipient: to, amount: "1")
        let draft = try XCTUnwrap(c.review)
        let record = PendingTransfer(draft: draft, state: .outcomeUnknown)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        var old = json["draft"] as! [String: Any]; old.removeValue(forKey: "recipientCredit"); json["draft"] = old
        let decoded = try JSONDecoder().decode(PendingTransfer.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.draft.recipientCredit); try decoded.draft.validate()
        j.records = [decoded]
        let recovered = SendCoordinator(network: n, journal: j); recovered.select(w)
        XCTAssertNotNil(recovered.unresolved(w))
        await recovered.prepare(wallet: w, recipient: to, amount: "1")
        XCTAssertEqual(recovered.failure, .alreadyRecorded)
    }
    func testJournalFailurePreventsWriteAndLocksFurtherSending() async throws {
        let (c,n,j,s,w,to) = try setup()
        await c.prepare(wallet: w, recipient: to, amount: "1"); j.fails = true
        await c.confirm(approved: c.review, signer: s)
        XCTAssertEqual(c.failure, .journal)
        let writes = await n.submissions; XCTAssertEqual(writes, 0)
        j.fails = false
        await c.confirm(approved: c.review, signer: s); XCTAssertEqual(s.calls, 1)
    }
    func testTimeoutRestartNotFoundNeverResendOrUnlock() async throws {
        let (c,n,j,s,w,to) = try setup()
        await c.prepare(wallet: w, recipient: to, amount: "1"); await n.configure(timeout: true)
        await c.confirm(approved: c.review, signer: s); XCTAssertEqual(c.phase, .outcomeUnknown)
        let restarted = SendCoordinator(network: n, journal: j)
        restarted.select(w); await n.configure(result: .outcomeUnknown)
        await restarted.reconcile(try XCTUnwrap(j.records.first))
        XCTAssertNotNil(restarted.unresolved(w)); XCTAssertEqual(restarted.phase, .draft)
        await restarted.prepare(wallet: w, recipient: to, amount: "1")
        XCTAssertEqual(restarted.message, SendFailure.alreadyRecorded.message)
        let writes = await n.submissions; XCTAssertEqual(writes, 1)
    }
    func testMalformedSubmissionResponseBecomesUnknown() async throws {
        let (c,n,j,s,w,to) = try setup()
        await c.prepare(wallet: w, recipient: to, amount: "1"); await n.configure(mismatch: true)
        await c.confirm(approved: c.review, signer: s)
        XCTAssertEqual(c.phase, .outcomeUnknown); XCTAssertEqual(j.records.first?.state, .outcomeUnknown)
    }
    func testDuplicateTapsAndSelectionLogoutRaceKeepJournalLock() async throws {
        let (c,n,j,s,w,to) = try setup()
        await c.prepare(wallet: w, recipient: to, amount: "1"); await n.configure(delay: true)
        let first = Task { await c.confirm(approved: c.review, signer: s) }
        await Task.yield(); await c.confirm(approved: c.review, signer: s)
        // Wait until actual submission, then model wallet logout/switch without deleting the journal.
        for _ in 0..<100 { if await n.submissions == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
        c.select(nil); await first.value
        XCTAssertEqual(c.phase, .draft)
        let writes = await n.submissions; XCTAssertEqual(writes, 1)
        let restarted = SendCoordinator(network: n, journal: j); restarted.select(w)
        XCTAssertNotNil(restarted.unresolved(w)); XCTAssertEqual(s.calls, 1)
    }
    func testSelectionChangeDuringPrepareRejectsLateReview() async throws {
        let (c,n,_,_,w,to) = try setup(); await n.configure(delay: true)
        let task = Task { await c.prepare(wallet: w, recipient: to, amount: "1") }
        await Task.yield(); c.select(nil); await task.value
        XCTAssertNil(c.review); XCTAssertEqual(c.phase, .draft)
    }
    func testRestartSubmittingAndFinalFailedState() async throws {
        let (c,n,j,_,w,to) = try setup(); await c.prepare(wallet: w, recipient: to, amount: "1")
        j.records = [PendingTransfer(draft: try XCTUnwrap(c.review), state: .submitting)]
        let recovered = SendCoordinator(network: n, journal: j); recovered.select(w)
        XCTAssertEqual(recovered.phase, .draft)
        await n.configure(result: .pending); await recovered.reconcile(try XCTUnwrap(j.records.first)); XCTAssertEqual(recovered.phase, .draft)
        await n.configure(result: .failed); await recovered.reconcile(try XCTUnwrap(j.records.first)); XCTAssertEqual(recovered.phase, .draft)
        XCTAssertNotNil(recovered.unresolved(w))
    }
    func testFileJournalRoundTripAndMalformedFailClosed() async throws {
        let (c,_,_,_,w,to) = try setup(); await c.prepare(wallet: w, recipient: to, amount: "1")
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "pending.json"), journal = FileTransferJournal(url: url)
        let draft = try XCTUnwrap(c.review)
        try journal.write([PendingTransfer(draft: draft, state: .submitting)])
        XCTAssertEqual(try journal.read().first?.draft.operationID, draft.operationID)
        let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
        let resolved = protection as? FileProtectionType ?? (protection as? String).map { FileProtectionType(rawValue: $0) }
        #if targetEnvironment(simulator)
        // This runtime may omit Data Protection attributes. Physical protection is a separate device gate.
        XCTAssertTrue(resolved == nil || resolved == .complete)
        #else
        XCTAssertEqual(resolved, .complete)
        #endif
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(envelope["version"] as? Int, 2)
        let object = envelope["records"] as! [[String: Any]]
        XCTAssertNil(object.first?["signature"]); XCTAssertNil(object.first?["privateKey"])
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try journal.read())
    }
}

@MainActor private final class SigningStore: TestAccountSecretStore {
    var bytes: Data?; var loads = 0; var storageCancelled = false
    init(_ bytes: Data?) { self.bytes = bytes }
    func saveNew(_ seed: Data) throws { bytes = seed }
    func load(context: LAContext?) throws -> Data? { loads += 1; if storageCancelled { throw TestAccountStorageError.keychain(errSecUserCanceled) }; return bytes }
    func delete() throws { bytes = nil }
}
@MainActor private final class SigningAuth: WalletAuthenticating {
    var fail = false
    func authorize(reason: String) async throws -> LAContext { if fail { throw OnboardingError.cancelled }; return LAContext() }
    func cancel() {}
}
@MainActor private final class SigningMetadata: WalletMetadataStoring {
    let record: WalletRecord
    init(_ identity: MassaPublicAccount) { record = WalletRecord(identity) }
    func load() -> WalletRecord? { record }
    func save(_ record: WalletRecord) {}
}
extension SendCoordinatorTests {
    func testExistingProtectedBoundaryChecksIdentityAndNeverExports() async throws {
        for mode in 0...4 {
            let account = MassaTestAccount(), identity = try account.publicAccount, w = try wallet(account)
            let store = SigningStore(mode == 1 ? MassaTestAccount().storageData() : mode == 2 ? nil : account.storageData())
            store.storageCancelled = mode == 4
            let auth = SigningAuth(); auth.fail = mode == 3
            let access = WalletOnboarding(store: store, authentication: auth, metadata: SigningMetadata(identity))
            access.updatePrivacy(active: true, captured: false)
            let n = MockNetwork(), c = SendCoordinator(network: n, journal: MemoryJournal())
            c.select(w); await c.prepare(wallet: w, recipient: try MassaTestAccount().publicAccount.address, amount: "1")
            await c.confirm(approved: c.review, signer: ProtectedTransferSigner(access: access))
            let writes = await n.submissions
            XCTAssertEqual(writes, mode == 0 ? 1 : 0)
            XCTAssertEqual(store.loads, mode == 3 ? 0 : 1)
            XCTAssertNil(access.revealedKey); XCTAssertFalse(access.isRevealed)
            if mode > 0 { XCTAssertEqual(c.message, (mode == 3 || mode == 4) ? SendFailure.cancelled.message : SendFailure.keyUnavailable.message) }
        }
    }
    func testCapturedAppNeverLoadsProtectedKey() async throws {
        let account = MassaTestAccount(), w = try wallet(account), store = SigningStore(account.storageData())
        let access = WalletOnboarding(store: store, authentication: SigningAuth(), metadata: SigningMetadata(try account.publicAccount))
        access.updatePrivacy(active: true, captured: true)
        let n = MockNetwork(), c = SendCoordinator(network: n, journal: MemoryJournal())
        c.select(w); await c.prepare(wallet: w, recipient: try MassaTestAccount().publicAccount.address, amount: "1")
        await c.confirm(approved: c.review, signer: ProtectedTransferSigner(access: access))
        XCTAssertEqual(store.loads, 0); XCTAssertEqual(c.message, SendFailure.privacy.message)
    }
}

extension SendCoordinatorTests {
    func testVisibleSendErrorRelocalizesWithoutNewRequest() async throws {
        let previous = UserDefaults.standard.object(forKey: "app.language")
        defer { if let previous { UserDefaults.standard.set(previous, forKey: "app.language") } else { UserDefaults.standard.removeObject(forKey: "app.language") } }
        UserDefaults.standard.set("en", forKey: "app.language")
        let (_,n,j,s,w,to) = try setup(), c = SendCoordinator(network: n, journal: j)
        c.select(w); await c.prepare(wallet: w, recipient: to, amount: "99")
        let before = c.message
        UserDefaults.standard.set("ru", forKey: "app.language")
        XCTAssertNotEqual(before, c.message)
        XCTAssertEqual(c.message, SendFailure.funds.message)
        XCTAssertEqual(s.calls, 0)
    }
}

extension SendCoordinatorTests {
    func testCompletedOperationIDCannotBeReusedWithinSamePeriod() async throws {
        let (c,n,j,s,w,to) = try setup()
        await c.prepare(wallet: w, recipient: to, amount: "1"); await c.confirm(approved: c.review, signer: s)
        await n.configure(result: .finalized)
        await c.reconcile(try XCTUnwrap(j.records.first))
        XCTAssertEqual(c.phase, .outcomeUnknown)
        await c.prepare(wallet: w, recipient: to, amount: "1")
        XCTAssertNil(c.review); XCTAssertEqual(c.failure, .alreadyRecorded)
        await c.confirm(approved: c.review, signer: s)
        let writes = await n.submissions; XCTAssertEqual(writes, 1)
        let restarted = SendCoordinator(network: n, journal: j); restarted.select(w)
        await restarted.prepare(wallet: w, recipient: to, amount: "1")
        XCTAssertEqual(restarted.failure, .alreadyRecorded)
    }
    func testInvalidRecipientAndWalletSwitchClearOldError() async throws {
        let (c,n,_,_,w,_) = try setup()
        await c.prepare(wallet: w, recipient: "AUbad", amount: "1")
        XCTAssertEqual(c.failure, .recipient)
        let reads = await n.snapshots; XCTAssertEqual(reads, 0)
        c.select(nil); XCTAssertNil(c.failure); XCTAssertNil(c.message)
    }
}

extension SendCoordinatorTests {
    func testManualApprovalCannotAuthorizeAReplacedDraft() async throws {
        let (c,n,_,s,w,to) = try setup()
        await c.prepare(wallet: w, recipient: to, amount: "1")
        let approved = try XCTUnwrap(c.review)
        c.invalidateReview()
        await c.prepare(wallet: w, recipient: to, amount: "2")
        await c.confirm(approved: approved, signer: s)
        XCTAssertEqual(c.failure, .changed); XCTAssertEqual(s.calls, 0)
        let writes = await n.submissions; XCTAssertEqual(writes, 0)
        XCTAssertEqual(c.review?.amount.text, "2")
    }
    func testKnownUnsafeFundedRecipientRemainsBlocked() async throws {
        let (c,n,_,_,w,_) = try setup()
        let unsafe = try XCTUnwrap(KnownUnsafeWallets.addresses.first)
        await c.prepare(wallet: w, recipient: unsafe, amount: "1")
        XCTAssertEqual(c.failure, .recipient)
        let reads = await n.snapshots; XCTAssertEqual(reads, 0)
        let snap = try await n.snapshot(source: w.address, recipient: unsafe)
        XCTAssertThrowsError(try ReviewedTransfer.make(wallet: w, recipient: unsafe, amount: "1", snapshot: snap, now: Date()))
    }
}


extension SendCoordinatorTests {
    private func provenanceDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "r1-provenance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func provenanceBytes(_ records: [PendingTransfer], version: Int? = nil) throws -> Data {
        let data = try JSONEncoder().encode(records)
        guard let version else { return data }
        return try JSONSerialization.data(withJSONObject: ["version": version,
            "installationID": TransferTestContinuity.id.uuidString,
            "records": JSONSerialization.jsonObject(with: data)])
    }
    func testLegacyTerminalSubmissionNeverAuthorizesSameHumanPaymentNextPeriod() async throws {
        for envelope in [false, true] {
            for outcome in [SubmissionState.finalized, .failed] {
                for hasOldAssessment in [false, true] {
                    let (original, oldNetwork, _, originalSigner, wallet, recipient) = try setup()
                    await original.prepare(wallet: wallet, recipient: recipient, amount: "1")
                    let draft = try XCTUnwrap(original.review)
                    await oldNetwork.configure(timeout: true)
                    await original.confirm(approved: draft, signer: originalSigner)
                    XCTAssertNotNil(original.unresolved(wallet))
                    // Direct skipped-version upgrade: old node policy wrote a terminal label
                    // for a locally submitted intent, optionally with the old .observed shape.
                    let assessment = hasOldAssessment ? ReconciliationAssessment(state: outcome, reason: .observed,
                        checkedAt: draft.reviewedAt, reportedFinalPeriod: 999) : nil
                    let old = PendingTransfer(draft: draft, state: outcome, assessment: assessment)
                    let dir = try provenanceDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
                    let url = dir.appending(path: "journal.json")
                    try provenanceBytes([old], version: envelope ? 2 : nil).write(to: url)
                    let network = MockNetwork(); await network.setPeriod(101)
                    let migrated = SendCoordinator(network: network, journal: FileTransferJournal(url: url)); migrated.select(wallet)
                    XCTAssertNil(migrated.journalIssue); XCTAssertEqual(migrated.unresolved(wallet)?.draft, draft)
                    XCTAssertEqual(migrated.pending.first?.tracking, .localSubmission)
                    XCTAssertEqual(migrated.pending.first?.assessment?.reportedState, outcome)
                    await migrated.prepare(wallet: wallet, recipient: recipient, amount: "1")
                    XCTAssertNil(migrated.failure); XCTAssertEqual(migrated.phase, .review)
                    let signer = MockSigner(originalSigner.account)
                    await migrated.confirm(approved: draft, signer: signer)
                    XCTAssertEqual(signer.calls, 0)
                    let counts = await (network.snapshots, network.submissions)
                    XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 0)
                    let restarted = SendCoordinator(network: network, journal: FileTransferJournal(url: url))
                    XCTAssertEqual(restarted.pending, migrated.pending)
                    XCTAssertEqual(restarted.unresolved(wallet)?.draft.operationID, draft.operationID)
                }
            }
        }
    }
    func test8515HistoricalTagsColdStartAndRepeatedMigrationRemainLocalWithAllObservations() async throws {
        for state in [SubmissionState.finalized, .failed, .outcomeUnknown, .submitting] {
            let (prepared, network, _, _, wallet, recipient) = try setup()
            await prepared.prepare(wallet: wallet, recipient: recipient, amount: "1")
            let draft = try XCTUnwrap(prepared.review), now = Date()
            let observations = [SubmissionState.finalized, .failed].map {
                NodeObservation(operationID: draft.operationID, chainID: 77658377, endpoint: "https://fixture.invalid/rpc",
                    operatorID: "unverified-test", nodeVersion: "MAIN.5.0", reportedState: $0,
                    observedAt: now, reportedFinalPeriod: 999)
            }
            let evidence = ReconciliationAssessment(state: state, reason: .conflictingObservations,
                checkedAt: now, reportedFinalPeriod: 999, reportedState: .failed,
                observations: observations, terminalClaims: [.failed, .finalized])
            let record = PendingTransfer(draft: draft, state: state, assessment: evidence, tracking: .historicalNodeReport)
            let dir = try provenanceDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appending(path: "journal.json")
            try provenanceBytes([record], version: 2).write(to: url)
            let migrated = SendCoordinator(network: network, journal: FileTransferJournal(url: url)); migrated.select(wallet)
            XCTAssertNil(migrated.journalIssue); XCTAssertNotNil(migrated.unresolved(wallet))
            let saved = try XCTUnwrap(migrated.pending.first)
            XCTAssertEqual(saved.draft, draft); XCTAssertEqual(saved.state, .outcomeUnknown)
            XCTAssertEqual(saved.tracking, .localSubmission)
            XCTAssertEqual(saved.assessment?.observations, observations)
            XCTAssertEqual(saved.assessment?.terminalClaims, evidence.terminalClaims)
            XCTAssertEqual(saved.assessment?.reason, .conflictingObservations)
            XCTAssertTrue(migrated.reloadJournal()); XCTAssertEqual(migrated.pending.first, saved)
            for _ in 0..<2 {
                let restart = SendCoordinator(network: network, journal: FileTransferJournal(url: url))
                XCTAssertEqual(restart.pending.first, saved); XCTAssertNotNil(restart.unresolved(wallet))
            }
            await migrated.prepare(wallet: wallet, recipient: recipient, amount: "2")
            XCTAssertNil(migrated.failure); XCTAssertEqual(migrated.phase, .review)
            let writes = await network.submissions; XCTAssertEqual(writes, 0)
        }
    }
    func testReorderedMultiSourceRecordsKeepEveryIntentAndUnaffectedWalletCanSend() async throws {
        let (prepared, network, journal, _, wallet, recipient) = try setup()
        await prepared.prepare(wallet: wallet, recipient: recipient, amount: "1")
        let first = try XCTUnwrap(prepared.review)
        let otherAccount = MassaTestAccount(), other = try self.wallet(otherAccount)
        let snapshot = try await network.snapshot(source: other.address, recipient: recipient)
        let second = try ReviewedTransfer.make(wallet: other, recipient: recipient, amount: "2", snapshot: snapshot, now: Date())
        journal.records = [PendingTransfer(draft: first, state: .finalized), PendingTransfer(draft: second, state: .failed)]
        let send = SendCoordinator(network: network, journal: journal)
        let originals = send.pending
        journal.records.reverse(); XCTAssertTrue(send.reloadJournal())
        XCTAssertEqual(Set(send.pending.map { $0.draft.operationID }), Set(originals.map { $0.draft.operationID }))
        for source in [wallet, other] {
            send.select(source); XCTAssertNotNil(send.unresolved(source))
            await send.prepare(wallet: source, recipient: recipient, amount: "3")
            XCTAssertNil(send.failure); XCTAssertEqual(send.phase, .review)
        }
        let fresh = MassaTestAccount(), newWallet = try self.wallet(fresh), signer = MockSigner(fresh)
        send.select(newWallet); await send.prepare(wallet: newWallet, recipient: recipient, amount: "1")
        XCTAssertEqual(send.phase, .review)
        await send.confirm(approved: send.review, signer: signer)
        XCTAssertEqual(signer.calls, 1); XCTAssertEqual(send.phase, .pending)
        XCTAssertEqual(send.pending.count, 3)
        let writes = await network.submissions; XCTAssertEqual(writes, 1)
        let restart = SendCoordinator(network: network, journal: journal)
        for source in [wallet, other, newWallet] { XCTAssertNotNil(restart.unresolved(source)) }
    }
    func testFailedTerminalMigrationReplacementPreservesOldBytesAndBlocksUntilRecovery() async throws {
        let (prepared, network, _, _, wallet, recipient) = try setup()
        await prepared.prepare(wallet: wallet, recipient: recipient, amount: "1")
        let draft = try XCTUnwrap(prepared.review)
        let dir = try provenanceDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "journal.json"), bytes = try provenanceBytes([PendingTransfer(draft: draft, state: .finalized)])
        try bytes.write(to: url); _ = try FileTransferJournal(url: url).read() // Isolate replacement failure from marker creation.
        let failed = SendCoordinator(network: network, journal: FileTransferJournal(url: url, replace: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }))
        failed.select(wallet); XCTAssertEqual(failed.journalIssue, .unavailable)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        await failed.prepare(wallet: wallet, recipient: recipient, amount: "1")
        XCTAssertEqual(failed.failure, .journal)
        let recovered = SendCoordinator(network: network, journal: FileTransferJournal(url: url))
        XCTAssertNil(recovered.journalIssue); XCTAssertEqual(recovered.unresolved(wallet)?.draft, draft)
        let writes = await network.submissions; XCTAssertEqual(writes, 0)
    }
    func testForgedHistoricalRoleCannotUnlockColdButValidEmptyRollbackRemainsUnsolved() async throws {
        let (prepared, network, _, _, wallet, recipient) = try setup()
        await prepared.prepare(wallet: wallet, recipient: recipient, amount: "1")
        let draft = try XCTUnwrap(prepared.review)
        let dir = try provenanceDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "journal.json"), journal = FileTransferJournal(url: url)
        let forged = PendingTransfer(draft: draft, state: .outcomeUnknown,
            assessment: ReconciliationAssessment(state: .outcomeUnknown, reason: .uncorroboratedTerminal,
                checkedAt: Date(), reportedFinalPeriod: 999, reportedState: .failed), tracking: .historicalNodeReport)
        try journal.write([forged])
        let cold = SendCoordinator(network: network, journal: FileTransferJournal(url: url))
        XCTAssertEqual(cold.unresolved(wallet)?.draft, draft)
        var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        envelope["records"] = [] as [String]
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        XCTAssertFalse(cold.reloadJournal()); XCTAssertEqual(cold.journalIssue, .inconsistent)
        let rollback = SendCoordinator(network: network, journal: FileTransferJournal(url: url)); rollback.select(wallet)
        XCTAssertNil(rollback.journalIssue); XCTAssertNil(rollback.unresolved(wallet)) // OPEN R2, not a passing security guarantee.
        await rollback.prepare(wallet: wallet, recipient: recipient, amount: "2")
        XCTAssertEqual(rollback.phase, .review)
        let writes = await network.submissions; XCTAssertEqual(writes, 0)
    }
    func testUnknownTrackingVersionAndDuplicateRecordsFailClosedWithoutOverwrite() async throws {
        let (prepared, network, _, _, wallet, recipient) = try setup()
        await prepared.prepare(wallet: wallet, recipient: recipient, amount: "1")
        let draft = try XCTUnwrap(prepared.review), record = PendingTransfer(draft: draft, state: .outcomeUnknown)
        let dir = try provenanceDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        var object = try JSONSerialization.jsonObject(with: provenanceBytes([record], version: 2)) as! [String: Any]
        var rows = object["records"] as! [[String: Any]]; rows[0]["tracking"] = "future"; object["records"] = rows
        for bytes in [try provenanceBytes([record], version: 999), try provenanceBytes([record, record], version: 2),
                      try JSONSerialization.data(withJSONObject: object), Data(try provenanceBytes([record]).dropLast())] {
            let url = dir.appending(path: UUID().uuidString); try bytes.write(to: url)
            let send = SendCoordinator(network: network, journal: FileTransferJournal(url: url))
            XCTAssertEqual(send.journalIssue, .corrupt); XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
    func testPublicIntentMetadataCannotClaimHistoryOrClearExistingSourceLock() async throws {
        let (prepared, network, journal, _, wallet, recipient) = try setup()
        await prepared.prepare(wallet: wallet, recipient: recipient, amount: "1")
        let draft = try XCTUnwrap(prepared.review)
        var object = try JSONSerialization.jsonObject(with: PublicOperationFile(operations: [draft]).encoded()) as! [String: Any]
        object["tracking"] = "historicalNodeReport"; object["state"] = "finalized"; object["complete"] = true
        let file = try PublicOperationFile.decode(JSONSerialization.data(withJSONObject: object), for: wallet)
        let restored = SendCoordinator(network: network, journal: journal); restored.select(wallet)
        try restored.restorePublicOperations(file, for: wallet)
        let original = restored.pending
        XCTAssertEqual(original.first?.tracking, .localSubmission)
        try restored.restorePublicOperations(file, for: wallet); XCTAssertEqual(restored.pending, original)
        let restarted = SendCoordinator(network: network, journal: journal); restarted.select(wallet)
        await restarted.prepare(wallet: wallet, recipient: recipient, amount: "2")
        XCTAssertNil(restarted.failure); XCTAssertEqual(restarted.phase, .review); XCTAssertEqual(restarted.unresolved(wallet)?.draft, draft)
        let writes = await network.submissions; XCTAssertEqual(writes, 0)
    }
    func testWatchAndArchivedWalletsRemainIneligibleToSign() throws {
        let identity = try MassaTestAccount().publicAccount
        for kind in [ManagedWallet.Kind.owned, .watchOnly] {
            for storage in [ManagedWallet.Storage.current, .legacy] {
                let metadata = ManagedWallet(id: UUID().uuidString, name: "Disposable", address: identity.address,
                    publicKey: identity.publicKey, kind: kind, network: "Mainnet", backupAcknowledged: false, storage: storage)
                if kind == .owned && storage == .current { XCTAssertNoThrow(try SendWallet(metadata)) }
                else { XCTAssertThrowsError(try SendWallet(metadata)) }
            }
        }
    }
    func testDowngraded623UnknownRecordCannotBeGuessedHistoricalOrUnlockedByFinalClaim() async throws {
        let (preparer, network, journal, _, wallet, recipient) = try setup()
        await preparer.prepare(wallet: wallet, recipient: recipient, amount: "1")
        let original = try XCTUnwrap(preparer.review)
        let oldTerminal = PendingTransfer(draft: original, state: .finalized)
        journal.records = [PendingTransfer(draft: original, state: .outcomeUnknown, assessment: .retainingUnverified(oldTerminal))]
        let send = SendCoordinator(network: network, journal: journal); send.select(wallet)
        XCTAssertNotNil(send.unresolved(wallet)); XCTAssertEqual(send.pending.first?.tracking, .localSubmission)
        await network.configure(result: .finalized); await send.reconcile(try XCTUnwrap(send.pending.first))
        await send.prepare(wallet: wallet, recipient: recipient, amount: "2")
        XCTAssertNil(send.failure); XCTAssertEqual(send.phase, .review); XCTAssertEqual(send.pending.first?.draft, original)
        var forged = try XCTUnwrap(journal.records.first); forged.tracking = .historicalNodeReport
        journal.records = [forged]; XCTAssertTrue(send.reloadJournal())
        XCTAssertNotNil(send.unresolved(wallet)); XCTAssertEqual(send.pending.first?.tracking, .localSubmission)
        let writes = await network.submissions; XCTAssertEqual(writes, 0)
    }
}

@MainActor extension SendCoordinatorTests {
    func testUncertainHistoryAllowsNewReviewAcrossRestartSwitchAndReopenWithoutAutomaticSubmission() async throws {
        let (c,n,j,s,w,to) = try setup()
        await c.prepare(wallet: w, recipient: to, amount: "1")
        let original = try XCTUnwrap(c.review)
        await n.configure(timeout: true)
        await c.confirm(approved: original, signer: s)
        XCTAssertEqual(c.phase, .outcomeUnknown)
        let restarted = SendCoordinator(network: n, journal: j)
        restarted.select(w); XCTAssertEqual(restarted.phase, .draft); XCTAssertNil(restarted.review)
        restarted.select(nil); restarted.select(w)
        XCTAssertTrue(restarted.beginNewTransfer(for: w))
        await n.setPeriod(101)
        await restarted.prepare(wallet: w, recipient: to, amount: "1")
        let second = try XCTUnwrap(restarted.review)
        XCTAssertNotEqual(second.operationID, original.operationID)
        XCTAssertTrue(restarted.hasPossibleDuplicate(second))
        XCTAssertEqual(j.records.first?.draft, original)
        let before = await n.submissions; XCTAssertEqual(before, 1)
        // Only an explicitly approved new review may sign and dispatch the second operation.
        await n.configure()
        await restarted.confirm(approved: second, signer: s)
        await restarted.confirm(approved: second, signer: s)
        XCTAssertEqual(s.calls, 2)
        let after = await n.submissions; XCTAssertEqual(after, 2)
        XCTAssertEqual(Set(j.records.map { $0.draft.operationID }), Set([original.operationID, second.operationID]))
        let cold = SendCoordinator(network: n, journal: j); cold.select(w)
        XCTAssertNil(cold.review); XCTAssertEqual(cold.phase, .draft)
        await cold.confirm(approved: second, signer: s)
        let afterRestart = await n.submissions; XCTAssertEqual(afterRestart, 2)
        XCTAssertEqual(j.records.first(where: { $0.draft.operationID == original.operationID })?.state, .outcomeUnknown)
    }
    func testHistoryRefreshCannotReplaceIndependentImmutableReview() async throws {
        let (c,n,j,_,w,to) = try setup()
        await c.prepare(wallet: w, recipient: to, amount: "1")
        j.records = [PendingTransfer(draft: try XCTUnwrap(c.review), state: .outcomeUnknown)]
        XCTAssertTrue(c.reloadJournal()); c.select(w)
        await c.prepare(wallet: w, recipient: to, amount: "2")
        let review = try XCTUnwrap(c.review)
        await n.configure(result: .failed)
        await c.reconcile(try XCTUnwrap(j.records.first))
        XCTAssertEqual(c.review, review); XCTAssertEqual(c.phase, .review)
        XCTAssertNil(c.failure); XCTAssertFalse(c.hasPossibleDuplicate(review))
        let writes = await n.submissions; XCTAssertEqual(writes, 0)
    }
    func testUnknownHistoryAndAcknowledgementPresentationNeverInventExecution() async throws {
        let (c,_,_,_,w,to) = try setup()
        await c.prepare(wallet: w, recipient: to, amount: "1")
        let draft = try XCTUnwrap(c.review)
        for state in [SubmissionState.submitting, .pending, .outcomeUnknown, .finalized, .failed] {
            XCTAssertEqual(SendStatusPresentation.history(PendingTransfer(draft: draft, state: state)), state == .pending ? .submitted : .unknown)
        }
        XCTAssertEqual(SendStatusPresentation.attempt(.pending), .submitted)
        XCTAssertNil(SendStatusPresentation.attempt(.outcomeUnknown))
        XCTAssertEqual(SendStatusPresentation.history(PendingTransfer(draft: draft, state: .pending,
            assessment: .init(state: .pending, reason: .observed, checkedAt: Date(), reportedFinalPeriod: nil))), .pending)
    }
    func testNewPaymentWarningAllSixLanguagesAndNoHistoricalAcceptanceUI() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"))
        let bundle = try XCTUnwrap(Bundle(path: url.deletingLastPathComponent().path))
        XCTAssertFalse(bundle.bundlePath.isEmpty)
        for lang in AppLanguage.allCases {
            let localized = try XCTUnwrap(Bundle.main.path(forResource: lang.rawValue, ofType: "lproj"))
            let resource = try XCTUnwrap(Bundle(path: localized))
            for key in ["Submitted", "Status unavailable", "Submitted from this device", "A previous payment to this address for this amount has an unconfirmed result. This is a new payment and could transfer funds again."] {
                let text = resource.localizedString(forKey: key, value: "MISSING", table: nil)
                XCTAssertNotEqual(text, "MISSING")
                if lang != .english { XCTAssertNotEqual(text, key) }
            }
        }
    }
}

@MainActor extension SendCoordinatorTests {
    func testSlowHistoricalReadNeverLocksOrOverwritesNewPaymentReview() async throws {
        let (c,n,j,_,w,to) = try setup()
        await c.prepare(wallet: w, recipient: to, amount: "1")
        j.records = [PendingTransfer(draft: try XCTUnwrap(c.review), state: .outcomeUnknown)]
        XCTAssertTrue(c.reloadJournal()); c.select(w)
        await n.holdStatusRead()
        let old = try XCTUnwrap(c.pending.first)
        let reading = Task { await c.reconcile(old) }
        for _ in 0..<1000 { if await n.lookups > 0 { break }; await Task.yield() }
        XCTAssertTrue(c.reconcilingIDs.contains(old.draft.operationID)); XCTAssertFalse(c.busy)
        await c.prepare(wallet: w, recipient: to, amount: "2")
        let fresh = try XCTUnwrap(c.review); XCTAssertEqual(c.phase, .review)
        await n.releaseStatusRead(); await reading.value
        XCTAssertEqual(c.review, fresh); XCTAssertEqual(c.phase, .review)
        let submissions = await n.submissions; XCTAssertEqual(submissions, 0)
    }
}
