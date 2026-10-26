import XCTest
import LocalAuthentication
@testable import MassiveX

private actor TransferTransport: RPCTransport {
    var methods: [String] = []
    let mode: String
    let version: String
    init(_ mode: String = "valid", version: String = "MAIN.5.0") { self.mode = mode; self.version = version }
    func send(_ request: URLRequest) async throws -> RPCTransportResponse {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any], method = body["method"] as! String
        methods.append(method)
        var result: Any
        if method == "get_status" {
            result = ["chain_id": mode == "network" ? 1 : 77658377, "version": version, "last_slot": ["period": 100], "minimal_fees": mode == "fee" ? "1e3" : "0.012345678", "current_time": UInt64(Date().timeIntervalSince1970 * 1000) - (mode == "stale" ? 60_000 : 0), "config": ["operation_validity_periods": 10]] as [String: Any]
        } else if method == "get_addresses" {
            if mode == "delayedBalance" { try await Task.sleep(for: .milliseconds(100)) }
            let addresses = body["params"] as! [[String]]
            result = addresses[0].map { ["address": $0, "final_balance": "4.123456789", "candidate_balance": "4"] }
        } else if method == "get_operations" {
            let id = (body["params"] as! [[String]])[0][0]
            result = mode == "missing" ? [] : [["id": id, "in_pool": mode == "pool", "is_operation_final": mode == "final" || mode == "failed", "op_exec_status": mode == "pool" ? NSNull() : mode != "failed"]] as [[String: Any]]
        } else { throw SendFailure.response }
        return RPCTransportResponse(data: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": mode == "id" ? "wrong" : body["id"]!, "result": result]), statusCode: 200)
    }
}
final class TransferRPCTests: XCTestCase {
    func testDynamicFeeBalanceAndWrongNetworkStalenessFailClosed() async throws {
        let source = try MassaTestAccount().publicAccount.address, recipient = try MassaTestAccount().publicAccount.address
        let snapshot = try await MainnetTransferRPC(transport: TransferTransport()).snapshot(source: source, recipient: recipient)
        XCTAssertEqual(snapshot.fee.nano, 12_345_678); XCTAssertEqual(snapshot.spendable.text, "4"); XCTAssertEqual(snapshot.period, 100)
        let delayed = try await MainnetTransferRPC(transport: TransferTransport("delayedBalance")).snapshot(source: source, recipient: recipient)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(delayed.fetched), 0.08)
        for mode in ["network", "stale", "fee", "id"] {
            do { _ = try await MainnetTransferRPC(transport: TransferTransport(mode)).snapshot(source: source, recipient: recipient); XCTFail("Invalid response accepted") } catch {}
        }
    }
    func testKnownIDNotFoundSpeculativeFinalAndFailedDecoding() async throws {
        let id = try MassaCodec.encode(Data(repeating: 17, count: 32), prefix: "O")
        for (mode, expected): (String, SubmissionState) in [("missing", .outcomeUnknown), ("pool", .pending), ("final", .finalized), ("failed", .failed)] {
            let state = try await MainnetTransferRPC(transport: TransferTransport(mode)).lookup(operationID: id)
            XCTAssertEqual(state, expected)
        }
    }
    func testExactSubmissionInputAndSignatureProtection() async throws {
        let account = MassaTestAccount(), publicAccount = try account.publicAccount
        let wallet = try SendWallet(ManagedWallet(id: UUID().uuidString, name: "Public test", address: publicAccount.address, publicKey: publicAccount.publicKey, kind: .owned, network: "Mainnet", backupAcknowledged: true))
        let snap = SendSnapshot(fetched: Date(), chainID: 77658377, period: 100, validity: 10, fee: MASAmount(nano: 1), finalBalance: MASAmount(nano: 100), candidateBalance: MASAmount(nano: 100), recipientFinal: MASAmount(nano: 1), recipientCandidate: MASAmount(nano: 1))
        let draft = try ReviewedTransfer.make(wallet: wallet, recipient: MassaTestAccount().publicAccount.address, amount: "0.000000001", snapshot: snap, now: Date())
        let signature = try account.signOperation(draft.content, expected: publicAccount)
        let input = try MainnetTransferRPC.input(draft, signature: signature)
        let encoded = try JSONEncoder().encode(TransferRequest(id: "test", method: "send_operations", params: [[input]]))
        let body = try JSONSerialization.jsonObject(with: encoded) as! [String: Any], params = body["params"] as! [[[String: Any]]]
        XCTAssertEqual(params.count, 1); XCTAssertEqual(params[0].count, 1)
        XCTAssertEqual(Set(params[0][0].keys), ["serialized_content", "creator_public_key", "signature"])
        XCTAssertEqual(params[0][0]["serialized_content"] as? [UInt8], Array(draft.content))
        let transport = TransferTransport()
        do { _ = try await MainnetTransferRPC(transport: transport).submit(draft, signature: signature); XCTFail("Mock deliberately has no submission response") }
        catch { XCTAssertEqual(error as? SendFailure, .response) }
        let methods = await transport.methods
        XCTAssertEqual(methods, ["send_operations"])
        XCTAssertThrowsError(try MainnetTransferRPC.input(draft, signature: "bad"))
        XCTAssertThrowsError(try account.signOperation(draft.content, expected: MassaTestAccount().publicAccount))
    }
}

/// Public wire-shaped data. All signing accounts are disposable/unfunded and memory-only.
enum TrustedRPCFixture {
    static func operation(_ draft: ReviewedTransfer, signature: String, state: SubmissionState) -> [String: Any] {
        ["id": draft.operationID, "in_pool": state == .pending,
         "is_operation_final": state == .finalized || state == .failed,
         "op_exec_status": state == .outcomeUnknown ? NSNull() : state != .failed,
         "operation": ["id": draft.operationID, "content_creator_pub_key": draft.wallet.publicKey,
            "content_creator_address": draft.wallet.address, "signature": signature,
            "content": ["fee": draft.fee.text, "expire_period": draft.expiry,
                "op": ["Transaction": ["recipient_address": draft.recipient, "amount": draft.amount.text]]]]]
    }
}
private actor TrustedResolutionTransport: RPCTransport {
    let draft: ReviewedTransfer
    let signature: String
    let states: [SubmissionState]
    let mode: String
    let version: String
    private(set) var reads = 0, writes = 0
    init(_ draft: ReviewedTransfer, signature: String, states: [SubmissionState] = [.finalized], mode: String = "valid", version: String = "MAIN.5.0") {
        self.draft = draft; self.signature = signature; self.states = states; self.mode = mode; self.version = version
    }
    func send(_ request: URLRequest) async throws -> RPCTransportResponse {
        guard request.url?.absoluteString == TrustedMassaRPCResolution.endpoint else { throw SendFailure.response }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let method = body["method"] as! String
        let result: Any
        if method == "get_status" {
            result = ["chain_id": mode == "chain" ? 1 : 77658377, "version": mode == "version" ? "other" : version,
                "last_slot": ["period": 101], "minimal_fees": "0.01", "current_time": UInt64(Date().timeIntervalSince1970 * 1000) - (mode == "stale" ? 60_000 : 0),
                "config": ["operation_validity_periods": 10], "execution_stats": ["final_cursor": ["period": 100]]] as [String: Any]
        } else if method == "get_operations" {
            let state = states[min(reads, states.count - 1)]; reads += 1
            if mode == "timeout" { throw URLError(.timedOut) }
            if mode == "delay" { try await Task.sleep(for: .milliseconds(30)) }
            var row = TrustedRPCFixture.operation(draft, signature: signature, state: state)
            var operation = row["operation"] as! [String: Any], content = operation["content"] as! [String: Any]
            switch mode {
            case "wrongID": row["id"] = "wrong"
            case "innerID": operation["id"] = "wrong"
            case "sourceKey": operation["content_creator_pub_key"] = "Pbad"
            case "sourceAddress": operation["content_creator_address"] = "AUbad"
            case "signature": operation["signature"] = "bad"
            case "amount": content["op"] = ["Transaction": ["recipient_address": draft.recipient, "amount": "2"]]
            case "recipient": content["op"] = ["Transaction": ["recipient_address": draft.wallet.address, "amount": draft.amount.text]]
            case "fee": content["fee"] = "0.02"
            case "expiry": content["expire_period"] = draft.expiry + 1
            case "precision": content["fee"] = "1e-2"
            case "nullOutcome": row["op_exec_status"] = NSNull()
            case "poolUnavailable": row["in_pool"] = false
            case "poolUnavailableFailure": row["in_pool"] = false; row["op_exec_status"] = false
            case "poolUnavailableUnknown": row["in_pool"] = false; row["op_exec_status"] = NSNull()
            case "stringOutcome": row["op_exec_status"] = "true"
            case "nullFinal": row["is_operation_final"] = NSNull()
            case "poolFinal": row["in_pool"] = true
            default: break
            }
            operation["content"] = content; row["operation"] = operation
            if mode == "noContent" { row.removeValue(forKey: "operation") }
            result = state == .outcomeUnknown ? [] : mode == "duplicate" ? [row, row] : [row]
        } else if method == "get_addresses" {
            result = (body["params"] as! [[String]])[0].map { ["address": $0, "final_balance": "10", "candidate_balance": "10"] }
        } else { writes += 1; XCTFail("Resolution transports must never submit"); throw SendFailure.response }
        return RPCTransportResponse(data: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0",
            "id": mode == "rpcID" ? "wrong" : body["id"]!, "result": result]), statusCode: mode == "http" ? 503 : 200)
    }
}
@MainActor private final class ResolutionJournal: TransferJournal {
    var records: [PendingTransfer]
    var fail = false
    var afterWrite: (([PendingTransfer]) -> Void)?
    init(_ record: PendingTransfer) { records = [record] }
    func read() throws -> [PendingTransfer] { records }
    func write(_ records: [PendingTransfer]) throws {
        if fail { throw TransferJournalError.unavailable }
        self.records = records; afterWrite?(records)
    }
}
@MainActor extension TransferRPCTests {
    private func resolutionFixture() throws -> (ReviewedTransfer, String) {
        let account = MassaTestAccount(), identity = try account.publicAccount
        let wallet = try SendWallet(ManagedWallet(id: UUID().uuidString, name: "Disposable RPC fixture",
            address: identity.address, publicKey: identity.publicKey, kind: .owned, network: "Mainnet", backupAcknowledged: false))
        let snapshot = SendSnapshot(fetched: Date(), chainID: 77658377, period: 100, validity: 10,
            fee: MASAmount(nano: 10_000_000), finalBalance: MASAmount(nano: 10_000_000_000), candidateBalance: MASAmount(nano: 9_000_000_000),
            recipientFinal: MASAmount(nano: 1), recipientCandidate: MASAmount(nano: 1))
        let draft = try ReviewedTransfer.make(wallet: wallet, recipient: MassaTestAccount().publicAccount.address,
            amount: "1", snapshot: snapshot, now: Date())
        return (draft, try account.signOperation(draft.content, expected: identity))
    }
    func testTrustedFinalSuccessAndFailurePersistBeforeSourceUnlockAndSurviveRestart() async throws {
        for outcome in [SubmissionState.finalized, .failed] {
            let (draft, signature) = try resolutionFixture(), transport = TrustedResolutionTransport(draft, signature: signature, states: [outcome])
            let journal = ResolutionJournal(PendingTransfer(draft: draft, state: .outcomeUnknown))
            let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal); coordinator.select(draft.wallet)
            var lockedAtCommit = false
            journal.afterWrite = { records in
                if records.first?.hasTrustedResolution == true { lockedAtCommit = coordinator.unresolved(draft.wallet) != nil }
            }
            await coordinator.reconcile(try XCTUnwrap(coordinator.pending.first))
            XCTAssertTrue(lockedAtCommit); XCTAssertNil(coordinator.unresolved(draft.wallet)); XCTAssertEqual(coordinator.phase, .draft)
            let saved = try XCTUnwrap(journal.records.first)
            XCTAssertTrue(saved.hasTrustedResolution); XCTAssertEqual(saved.draft, draft)
            XCTAssertEqual(saved.assessment?.providerResolution?.policy, TrustedMassaRPCResolution.policyID)
            let restarted = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
            XCTAssertNil(restarted.unresolved(draft.wallet)); XCTAssertEqual(restarted.pending.first, saved)
            // Checking a durable terminal receipt is not a resubmission or a new polling dependency.
            await restarted.reconcile(saved)
            let counts = await (transport.reads, transport.writes); XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 0)
        }
    }
    func testMissingSpeculativeNullAndContradictoryOutcomesCannotResolve() async throws {
        let cases: [([SubmissionState], String)] = [([.outcomeUnknown], "valid"), ([.pending], "valid"),
            ([.finalized], "nullFinal"), ([.finalized, .failed], "valid"), ([.finalized, .outcomeUnknown], "valid"),
            ([.finalized, .pending], "valid")]
        for (states, mode) in cases {
            let (draft, signature) = try resolutionFixture(), transport = TrustedResolutionTransport(draft, signature: signature, states: states, mode: mode)
            let journal = ResolutionJournal(PendingTransfer(draft: draft, state: .outcomeUnknown))
            let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal); coordinator.select(draft.wallet)
            await coordinator.reconcile(try XCTUnwrap(coordinator.pending.first))
            XCTAssertNotNil(coordinator.unresolved(draft.wallet)); XCTAssertNil(journal.records.first?.assessment?.providerResolution)
            let writes = await transport.writes; XCTAssertEqual(writes, 0)
        }
    }
    func testMalformedIdentityContentOutcomeAndProviderStatusNeverUnlock() async throws {
        for mode in ["wrongID", "innerID", "sourceKey", "sourceAddress", "signature", "amount", "recipient", "fee", "expiry", "precision",
                     "nullOutcome", "stringOutcome", "poolFinal", "noContent", "duplicate", "chain", "version", "stale", "rpcID", "timeout", "http"] {
            let (draft, signature) = try resolutionFixture(), transport = TrustedResolutionTransport(draft, signature: signature, mode: mode)
            let journal = ResolutionJournal(PendingTransfer(draft: draft, state: .outcomeUnknown))
            let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal); coordinator.select(draft.wallet)
            await coordinator.reconcile(try XCTUnwrap(coordinator.pending.first))
            XCTAssertNil(coordinator.failure, mode); XCTAssertNotNil(coordinator.unresolved(draft.wallet), mode)
            XCTAssertFalse(journal.records.first?.hasTrustedResolution ?? true, mode)
            let writes = await transport.writes; XCTAssertEqual(writes, 0)
        }
    }
    func testTerminalJournalWriteFailureRetainsLockAndRetryOnlyChecksStatus() async throws {
        let (draft, signature) = try resolutionFixture(), transport = TrustedResolutionTransport(draft, signature: signature)
        let journal = ResolutionJournal(PendingTransfer(draft: draft, state: .outcomeUnknown))
        let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal); coordinator.select(draft.wallet)
        journal.fail = true
        await coordinator.reconcile(try XCTUnwrap(coordinator.pending.first))
        XCTAssertEqual(coordinator.journalIssue, .unavailable); XCTAssertNotNil(coordinator.unresolved(draft.wallet))
        XCTAssertFalse(journal.records.first?.hasTrustedResolution ?? true)
        journal.fail = false; XCTAssertTrue(coordinator.reloadJournal()); XCTAssertNotNil(coordinator.unresolved(draft.wallet))
        await coordinator.reconcile(try XCTUnwrap(coordinator.pending.first))
        XCTAssertNil(coordinator.unresolved(draft.wallet))
        let counts = await (transport.reads, transport.writes); XCTAssertEqual(counts.0, 4); XCTAssertEqual(counts.1, 0)
    }
    func testMigratedHistoricalRecordsRequireFreshMatchingResolutionAndConflictsStayLocked() async throws {
        for outcome in [SubmissionState.finalized, .failed] {
            for contradict in [false, true] {
                let (draft, signature) = try resolutionFixture()
                let transport = TrustedResolutionTransport(draft, signature: signature, states: [contradict ? (outcome == .finalized ? .failed : .finalized) : outcome])
                let journal = ResolutionJournal(PendingTransfer(draft: draft, state: outcome, tracking: .historicalNodeReport))
                let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
                XCTAssertNotNil(coordinator.unresolved(draft.wallet)); XCTAssertFalse(journal.records.first?.hasTrustedResolution ?? true)
                await coordinator.reconcile(try XCTUnwrap(coordinator.pending.first))
                XCTAssertEqual(coordinator.unresolved(draft.wallet) != nil, contradict)
                XCTAssertEqual(journal.records.first?.draft, draft)
                if contradict { XCTAssertEqual(journal.records.first?.assessment?.reason, .conflictingObservations) }
                let restart = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
                XCTAssertEqual(restart.unresolved(draft.wallet) != nil, contradict)
            }
        }
    }
    func testPersistedResolutionRejectsForgedEndpointChainSourcePolicyAndContent() async throws {
        let (draft, signature) = try resolutionFixture()
        let valid = try await MainnetTransferRPC(transport: TrustedResolutionTransport(draft, signature: signature)).reconciliation(for: draft)
        let record = PendingTransfer(draft: draft, state: .finalized, assessment: valid, tracking: .localSubmission)
        for mode in ["endpoint", "chain", "source", "content", "policy", "stale", "operator", "version"] {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
            var assessment = object["assessment"] as! [String: Any], resolution = assessment["providerResolution"] as! [String: Any]
            var reports = resolution["reports"] as! [[String: Any]], report = reports[0], observation = report["observation"] as! [String: Any]
            switch mode {
            case "endpoint": observation["endpoint"] = "https://mainnet.massa.net.evil.invalid/api/v2"
            case "chain": observation["chainID"] = 1
            case "version": observation["nodeVersion"] = "MAIN.5.2"
            case "source": report["sourceAddress"] = "AUbad"
            case "content": report["content"] = Data([0]).base64EncodedString()
            case "policy": resolution["policy"] = "unknown-policy"
            case "stale": observation["observedAt"] = 0
            default: observation["operatorID"] = "different-operator"
            }
            report["observation"] = observation; reports[0] = report; resolution["reports"] = reports
            assessment["providerResolution"] = resolution; object["assessment"] = assessment
            let decoded = try JSONDecoder().decode(PendingTransfer.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try TransferJournalPolicy.validate([decoded]), mode)
            XCTAssertFalse(decoded.hasTrustedResolution, mode)
        }
    }
    func testNormalPendingToFinalProgressDoesNotPermanentlyPoisonFreshMatchingConfirmation() async throws {
        let (draft, signature) = try resolutionFixture()
        let transport = TrustedResolutionTransport(draft, signature: signature, states: [.pending, .finalized, .finalized])
        let journal = ResolutionJournal(PendingTransfer(draft: draft, state: .outcomeUnknown))
        let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal); coordinator.select(draft.wallet)
        await coordinator.reconcile(try XCTUnwrap(coordinator.pending.first))
        XCTAssertNotNil(coordinator.unresolved(draft.wallet)) // A mixed bundle is insufficient.
        await coordinator.reconcile(try XCTUnwrap(coordinator.pending.first)) // A new complete two-read check.
        XCTAssertNil(coordinator.unresolved(draft.wallet))
        XCTAssertTrue(journal.records.first?.hasTrustedResolution ?? false)
        let writes = await transport.writes; XCTAssertEqual(writes, 0)
    }
    func testSelectionChangeDuringResolutionCannotOverwriteNewSelectionOrSubmit() async throws {
        let (draft, signature) = try resolutionFixture(), transport = TrustedResolutionTransport(draft, signature: signature, mode: "delay")
        let journal = ResolutionJournal(PendingTransfer(draft: draft, state: .outcomeUnknown))
        let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal); coordinator.select(draft.wallet)
        let record = try XCTUnwrap(coordinator.pending.first)
        let task = Task { await coordinator.reconcile(record) }
        for _ in 0..<100 { if await transport.reads > 0 { break }; await Task.yield() }
        coordinator.select(nil); await task.value
        XCTAssertEqual(coordinator.phase, .draft); XCTAssertNil(coordinator.review)
        XCTAssertNil(coordinator.unresolved(draft.wallet))
        let writes = await transport.writes; XCTAssertEqual(writes, 0)
    }
}

/// Memory-only RPC admission/error model. No URLSession, Keychain or live network path.
private actor AdmissionFailureTransport: RPCTransport {
    let mode: String
    let journalHasIntent: @MainActor @Sendable () -> Bool
    let reads = TransferTransport("missing", version: "MAIN.5.1")
    private(set) var submissions = 0
    init(_ mode: String, journalHasIntent: @escaping @MainActor @Sendable () -> Bool) {
        self.mode = mode; self.journalHasIntent = journalHasIntent
    }
    func send(_ request: URLRequest) async throws -> RPCTransportResponse {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        guard body["method"] as? String == "send_operations" else { return try await reads.send(request) }
        submissions += 1 // Models possible admission BEFORE the response fails.
        guard await journalHasIntent() else { XCTFail("Submission without durable intent"); throw SendFailure.journal }
        if mode == "lost" { throw URLError(.networkConnectionLost) }
        let response: [String: Any] = mode == "mismatchedID"
            ? ["jsonrpc": "2.0", "id": body["id"]!, "result": ["wrong"]]
            : ["jsonrpc": "2.0", "id": body["id"]!, "error": ["code": -32603, "message": "Admission outcome unknown"]]
        return RPCTransportResponse(data: try JSONSerialization.data(withJSONObject: response), statusCode: mode == "http" ? 503 : 200)
    }
}
@MainActor private final class CompatibilitySigner: TransferSigning {
    let account: MassaTestAccount
    var calls = 0
    init(_ account: MassaTestAccount) { self.account = account }
    func sign(_ draft: ReviewedTransfer) async throws -> String {
        calls += 1
        return try account.signOperation(draft.content, expected: account.publicAccount)
    }
    func cancel() {}
}
@MainActor extension TransferRPCTests {
    func testBothReviewedMainnetVersionsFetchDynamicParametersAndRejectUnknownVersions() async throws {
        let (draft, _) = try resolutionFixture()
        for version in ["MAIN.5.0", "MAIN.5.1"] {
            let snapshot = try await MainnetTransferRPC(transport: TransferTransport(version: version))
                .snapshot(source: draft.wallet.address, recipient: draft.recipient)
            XCTAssertEqual(snapshot.chainID, 77658377); XCTAssertEqual(snapshot.fee.nano, 12_345_678)
            XCTAssertEqual(snapshot.validity, 10); XCTAssertEqual(snapshot.period, 100)
            XCTAssertEqual(snapshot.spendable.text, "4")
        }
        for version in ["MAIN.5.2", "MAIN.6.0", "MAIN.5.10", "MAIN.5.1-extra", "main.5.1", "MAIN.5.1 ", ""] {
            let transport = TransferTransport(version: version)
            do { _ = try await MainnetTransferRPC(transport: transport).lookup(operationID: draft.operationID); XCTFail("Unreviewed version accepted") }
            catch { XCTAssertEqual(error as? SendFailure, .stale) }
            let methods = await transport.methods; XCTAssertEqual(methods, ["get_status"])
            let now = Date(), observation = NodeObservation(operationID: draft.operationID, chainID: 77658377,
                endpoint: TrustedMassaRPCResolution.endpoint, operatorID: "massa-labs", nodeVersion: version,
                reportedState: .pending, observedAt: now, reportedFinalPeriod: nil)
            let assessment = ReconciliationAssessment.combine(.pending, .pending, finalPeriod: nil, expiry: draft.expiry,
                now: now, operationID: draft.operationID, observations: [observation, observation])
            XCTAssertEqual(assessment.reason, .invalidEvidence); XCTAssertEqual(assessment.state, .outcomeUnknown)
        }
    }
    func testMain51TerminalSuccessFailureAndProvenanceSurviveSerializedRestart() async throws {
        for outcome in [SubmissionState.finalized, .failed] {
            let (draft, signature) = try resolutionFixture()
            let transport = TrustedResolutionTransport(draft, signature: signature, states: [outcome], version: "MAIN.5.1")
            let journal = ResolutionJournal(PendingTransfer(draft: draft, state: .outcomeUnknown))
            let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
            coordinator.select(draft.wallet)
            var lockedAtWrite = false
            journal.afterWrite = { rows in
                if rows.first?.hasTrustedResolution == true { lockedAtWrite = coordinator.unresolved(draft.wallet) != nil }
            }
            await coordinator.reconcile(try XCTUnwrap(coordinator.pending.first))
            XCTAssertTrue(lockedAtWrite); XCTAssertNil(coordinator.unresolved(draft.wallet))
            let data = try JSONEncoder().encode(journal.records)
            journal.records = try JSONDecoder().decode([PendingTransfer].self, from: data)
            let record = try XCTUnwrap(journal.records.first)
            XCTAssertEqual(record.draft, draft); XCTAssertEqual(record.state, outcome); XCTAssertTrue(record.hasTrustedResolution)
            XCTAssertEqual(record.assessment?.providerResolution?.reports.map(\.observation.nodeVersion), ["MAIN.5.1", "MAIN.5.1"])
            let restarted = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
            XCTAssertNil(restarted.unresolved(draft.wallet))
            await restarted.reconcile(record)
            let counts = await (transport.reads, transport.writes); XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 0)
        }
    }
    func testMain51PoolFalseNeverProvesTerminalAndMissingNeverUnlocks() async throws {
        for (state, mode) in [(SubmissionState.pending, "valid"), (.pending, "poolUnavailable"), (.pending, "poolUnavailableFailure"), (.pending, "poolUnavailableUnknown"), (.outcomeUnknown, "valid")] {
            let (draft, signature) = try resolutionFixture()
            let transport = TrustedResolutionTransport(draft, signature: signature, states: [state], mode: mode, version: "MAIN.5.1")
            let journal = ResolutionJournal(PendingTransfer(draft: draft, state: .outcomeUnknown))
            let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
            await coordinator.reconcile(try XCTUnwrap(coordinator.pending.first))
            XCTAssertNotNil(coordinator.unresolved(draft.wallet)); XCTAssertFalse(journal.records[0].hasTrustedResolution)
            XCTAssertEqual(journal.records[0].draft, draft)
            let writes = await transport.writes; XCTAssertEqual(writes, 0)
        }
    }
    func testMain51MalformedContradictoryAndDuplicateReportsKeepSourceLocked() async throws {
        for mode in ["wrongID", "innerID", "signature", "amount", "sourceKey", "chain", "stale", "duplicate", "nullOutcome", "poolFinal"] {
            let (draft, signature) = try resolutionFixture()
            let transport = TrustedResolutionTransport(draft, signature: signature, mode: mode, version: "MAIN.5.1")
            let journal = ResolutionJournal(PendingTransfer(draft: draft, state: .outcomeUnknown))
            let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
            await coordinator.reconcile(try XCTUnwrap(coordinator.pending.first))
            XCTAssertNil(coordinator.failure, mode); XCTAssertNotNil(coordinator.unresolved(draft.wallet), mode)
            XCTAssertEqual(journal.records[0].draft, draft); XCTAssertFalse(journal.records[0].hasTrustedResolution)
        }
        let (draft, signature) = try resolutionFixture()
        let transport = TrustedResolutionTransport(draft, signature: signature, states: [.finalized, .failed], version: "MAIN.5.1")
        let journal = ResolutionJournal(PendingTransfer(draft: draft, state: .outcomeUnknown))
        let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
        await coordinator.reconcile(try XCTUnwrap(coordinator.pending.first))
        XCTAssertEqual(journal.records[0].assessment?.reason, .conflictingObservations)
        let restarted = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
        await restarted.reconcile(try XCTUnwrap(restarted.pending.first))
        XCTAssertNotNil(restarted.unresolved(draft.wallet))
    }
    func testMain51JournalFailureCannotReleaseLockAndLegacyRoleNeedsFreshResolution() async throws {
        let (draft, signature) = try resolutionFixture()
        let transport = TrustedResolutionTransport(draft, signature: signature, version: "MAIN.5.1")
        let journal = ResolutionJournal(PendingTransfer(draft: draft, state: .finalized, tracking: .historicalNodeReport))
        let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
        XCTAssertNotNil(coordinator.unresolved(draft.wallet)); XCTAssertFalse(journal.records[0].hasTrustedResolution)
        journal.fail = true
        await coordinator.reconcile(try XCTUnwrap(coordinator.pending.first))
        XCTAssertNotNil(coordinator.unresolved(draft.wallet)); XCTAssertEqual(coordinator.journalIssue, .unavailable)
        XCTAssertFalse(journal.records[0].hasTrustedResolution)
        journal.fail = false
        let restarted = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
        XCTAssertNotNil(restarted.unresolved(draft.wallet))
        await restarted.reconcile(try XCTUnwrap(restarted.pending.first))
        XCTAssertNil(restarted.unresolved(draft.wallet)); XCTAssertEqual(journal.records[0].draft, draft)
        let writes = await transport.writes; XCTAssertEqual(writes, 0)
    }
    func testAdmissionThenRPCErrorHTTPDisconnectOrWrongIDNeverResubmitsAfterRestart() async throws {
        for mode in ["rpcError", "http", "lost", "mismatchedID"] {
            let account = MassaTestAccount(), identity = try account.publicAccount
            let wallet = try SendWallet(ManagedWallet(id: UUID().uuidString, name: "Disposable memory only",
                address: identity.address, publicKey: identity.publicKey, kind: .owned, network: "Mainnet", backupAcknowledged: false))
            let journal = ResolutionJournal(PendingTransfer(draft: try resolutionFixture().0, state: .outcomeUnknown))
            journal.records = []
            let transport = AdmissionFailureTransport(mode, journalHasIntent: { journal.records.contains { $0.state == .submitting && $0.draft.wallet == wallet } })
            let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
            let signer = CompatibilitySigner(account), recipient = try MassaTestAccount().publicAccount.address
            coordinator.select(wallet)
            await coordinator.prepare(wallet: wallet, recipient: recipient, amount: "1")
            let reviewed = try XCTUnwrap(coordinator.review)
            await coordinator.confirm(approved: reviewed, signer: signer)
            XCTAssertEqual(coordinator.phase, .outcomeUnknown); XCTAssertEqual(signer.calls, 1)
            XCTAssertEqual(journal.records[0].draft, reviewed); XCTAssertNotNil(coordinator.unresolved(wallet))
            let bytes = try JSONEncoder().encode(journal.records)
            journal.records = try JSONDecoder().decode([PendingTransfer].self, from: bytes)
            let restarted = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
            restarted.select(wallet)
            await restarted.confirm(approved: reviewed, signer: signer)
            await restarted.reconcile(try XCTUnwrap(restarted.pending.first)) // Empty does not prove rejection.
            await restarted.prepare(wallet: wallet, recipient: recipient, amount: "1")
            XCTAssertEqual(restarted.failure, .alreadyRecorded); XCTAssertNotNil(restarted.unresolved(wallet))
            XCTAssertEqual(journal.records[0].draft, reviewed)
            let submissions = await transport.submissions; XCTAssertEqual(submissions, 1); XCTAssertEqual(signer.calls, 1)
        }
    }
}

/// Authentic 2026-10-20 capture from audit 16, not a successful-transfer fixture.
/// Replaying normalizes only envelope IDs and the status clock. No network transport exists.
private actor CapturedMain51Transport: RPCTransport {
    var methods: [String] = []
    static let capture = Data(base64Encoded: "ewogICJmb3JtYXQiOiAibWFzc2l2ZS14LXB1YmxpYy1tYWlubmV0LW5lZ2F0aXZlLWNhcHR1cmUtdjEiLAogICJjb3ZlcmFnZSI6ICJORUdBVElWRSBPTkxZOiBlbXB0eSByZXN1bHQgZG9lcyBub3QgZXN0YWJsaXNoIGZhaWx1cmUgb3Igbm9uZXhlY3V0aW9uLiBQb3NpdGl2ZSBjb21wbGV0ZWQgYmFzaWMgTUFTIGFjY2VwdGFuY2UgaXMgTk9UIFRFU1RFRC4iLAogICJlbmRwb2ludCI6ICJodHRwczovL21haW5uZXQubWFzc2EubmV0L2FwaS92MiIsCiAgImNhcHR1cmVkVVRDIjogIjIwMjYtMTAtMjBUMTM6MzQ6NDAuNzEyNDEwKzAwOjAwIiwKICAicHVibGljT3BlcmF0aW9uSUQiOiAiTzFMTXI5eHlMOWZWU2JVdlphbzRqeTZ0MlBqNVVQdExHOHgxZnh2UzZTRDdkUGI1UzUyIiwKICAicHVibGljSURTb3VyY2UiOiAiaHR0cHM6Ly9kb2NzLm1hc3NhLm5ldC9kb2NzL2J1aWxkL2FwaS9qc29ucnBjI2dldF9vcGVyYXRpb25zIiwKICAic3RhdHVzUHJvamVjdGlvbiI6IHsKICAgICJqc29ucnBjIjogIjIuMCIsCiAgICAiaWQiOiAibmVnYXRpdmUtY2FwdHVyZS1nZXRfc3RhdHVzIiwKICAgICJyZXN1bHQiOiB7CiAgICAgICJjaGFpbl9pZCI6IDc3NjU4Mzc3LAogICAgICAidmVyc2lvbiI6ICJNQUlOLjUuMSIsCiAgICAgICJjdXJyZW50X3RpbWUiOiAxNzkyNTAzMjgwMjk0LAogICAgICAibGFzdF9zbG90IjogewogICAgICAgICJwZXJpb2QiOiA1NDQ5NDA1LAogICAgICAgICJ0aHJlYWQiOiAwCiAgICAgIH0sCiAgICAgICJtaW5pbWFsX2ZlZXMiOiAiMC4wMSIsCiAgICAgICJjb25maWciOiB7CiAgICAgICAgIm9wZXJhdGlvbl92YWxpZGl0eV9wZXJpb2RzIjogMTAKICAgICAgfSwKICAgICAgImV4ZWN1dGlvbl9zdGF0cyI6IHsKICAgICAgICAiZmluYWxfY3Vyc29yIjogewogICAgICAgICAgInBlcmlvZCI6IDU0NDk0MDIsCiAgICAgICAgICAidGhyZWFkIjogMzAKICAgICAgICB9CiAgICAgIH0KICAgIH0KICB9LAogICJvcGVyYXRpb25SZXNwb25zZSI6IHsKICAgICJqc29ucnBjIjogIjIuMCIsCiAgICAiaWQiOiAibmVnYXRpdmUtY2FwdHVyZS1nZXRfb3BlcmF0aW9ucyIsCiAgICAicmVzdWx0IjogW10KICB9LAogICJodHRwRXZpZGVuY2UiOiBbCiAgICB7CiAgICAgICJtZXRob2QiOiAiZ2V0X3N0YXR1cyIsCiAgICAgICJodHRwU3RhdHVzIjogMjAwLAogICAgICAiY29udGVudFR5cGUiOiAiYXBwbGljYXRpb24vanNvbjsgY2hhcnNldD11dGYtOCIsCiAgICAgICJzZXJ2ZXJEYXRlIjogIlR1ZSwgMjAgT2N0IDIwMjYgMTM6MzQ6NDAgR01UIiwKICAgICAgInJhd1NIQTI1NiI6ICIwMjUxNjk1NmNkNWQwN2IwY2Q0Njg3ZGY5YTM1ZWY0YWZjMTIyZDNiNmM5OTQwMDY2M2QwYjJhY2E4N2NmYjY4IgogICAgfSwKICAgIHsKICAgICAgIm1ldGhvZCI6ICJnZXRfb3BlcmF0aW9ucyIsCiAgICAgICJodHRwU3RhdHVzIjogMjAwLAogICAgICAiY29udGVudFR5cGUiOiAiYXBwbGljYXRpb24vanNvbjsgY2hhcnNldD11dGYtOCIsCiAgICAgICJzZXJ2ZXJEYXRlIjogIlR1ZSwgMjAgT2N0IDIwMjYgMTM6MzQ6NDAgR01UIiwKICAgICAgInJhd1NIQTI1NiI6ICI0NzZjZjBiNGI5ZDFhNDBmNTE4MzFmMDUzNmQzZTUxYmVkZDJkNmZlYmY0N2UxOTYwN2RjYjQ1NzBiOWQxZDUwIgogICAgfQogIF0sCiAgInJlcGxheU5vdGVzIjogIlN0YXR1cyBmaWVsZHMgYXJlIGFuIGF1dGhlbnRpYyBtaW5pbWFsIHByb2plY3Rpb24uIE9mZmxpbmUgcmVwbGF5IGNoYW5nZXMgb25seSBjdXJyZW50X3RpbWUgZm9yIHRoZSB0ZXN0IGNsb2NrIGFuZCBKU09OLVJQQyBlbnZlbG9wZSBJRHM7IHRoZSBvcGVyYXRpb24gcmVzdWx0IHN0YXlzIGV4YWN0bHkgZW1wdHkuIgp9Cg==")!
    func send(_ request: URLRequest) async throws -> RPCTransportResponse {
        let fixture = try JSONSerialization.jsonObject(with: Self.capture) as! [String: Any]
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let method = body["method"] as! String
        methods.append(method)
        guard request.url?.absoluteString == fixture["endpoint"] as? String else { throw SendFailure.response }
        var response: [String: Any]
        if method == "get_status" {
            response = fixture["statusProjection"] as! [String: Any]
            var status = response["result"] as! [String: Any]
            status["current_time"] = UInt64(Date().timeIntervalSince1970 * 1000)
            response["result"] = status
        } else if method == "get_operations" {
            guard body["params"] as? [[String]] == [[fixture["publicOperationID"] as! String]] else { throw SendFailure.response }
            response = fixture["operationResponse"] as! [String: Any]
        } else { XCTFail("Offline capture must never submit"); throw SendFailure.response }
        response["id"] = body["id"]
        return RPCTransportResponse(data: try JSONSerialization.data(withJSONObject: response), statusCode: 200)
    }
}
extension TransferRPCTests {
    func testAuthenticMain51NegativeCaptureDecodesAsUnknownNotTerminal() async throws {
        let fixture = try JSONSerialization.jsonObject(with: CapturedMain51Transport.capture) as! [String: Any]
        let status = (fixture["statusProjection"] as! [String: Any])["result"] as! [String: Any]
        XCTAssertEqual(status["version"] as? String, "MAIN.5.1")
        let transport = CapturedMain51Transport()
        let state = try await MainnetTransferRPC(transport: transport).lookup(operationID: fixture["publicOperationID"] as! String)
        XCTAssertEqual(state, .outcomeUnknown)
        let methods = await transport.methods; XCTAssertEqual(methods, ["get_status", "get_operations"])
    }
}

@MainActor extension TransferRPCTests {
    func testRecentRecipientsOnlyConfirmedSuccessSameSourceDeduplicatedAndDurable() async throws {
        let (draft, signature) = try resolutionFixture()
        let rpc = MainnetTransferRPC(transport: TrustedResolutionTransport(draft, signature: signature, version: "MAIN.5.1"))
        let assessment = try await rpc.reconciliation(for: draft)
        let confirmed = PendingTransfer(draft: draft, state: .finalized, assessment: assessment)
        let pending = PendingTransfer(draft: draft, state: .pending)
        let historical = PendingTransfer(draft: draft, state: .finalized, tracking: .historicalNodeReport)
        let (other, otherSignature) = try resolutionFixture()
        let otherAssessment = try await MainnetTransferRPC(transport: TrustedResolutionTransport(other, signature: otherSignature)).reconciliation(for: other)
        let otherSource = PendingTransfer(draft: other, state: .finalized, assessment: otherAssessment)
        let failedAssessment = try await MainnetTransferRPC(transport: TrustedResolutionTransport(draft, signature: signature, states: [.failed])).reconciliation(for: draft)
        let failed = PendingTransfer(draft: draft, state: .failed, assessment: failedAssessment)
        XCTAssertTrue(SendRecentRecipients.make([pending,historical,failed,otherSource],for:draft.wallet).isEmpty)
        let records = [pending,historical,confirmed,confirmed,failed,otherSource]
        let restored = try JSONDecoder().decode([PendingTransfer].self, from: JSONEncoder().encode(records))
        let recent = SendRecentRecipients.make(restored,for:draft.wallet)
        XCTAssertEqual(recent.count,1); XCTAssertEqual(recent.first?.address,draft.recipient)
        XCTAssertEqual(SendRecentRecipients.make(restored,for:other.wallet).first?.address,other.recipient)
    }
}

@MainActor extension TransferRPCTests {
    func testOldUnverifiedTerminalBecomesDurableReceiptAndFreshManualReview() async throws {
        for outcome in [SubmissionState.finalized, .failed] {
            let (current, signature) = try resolutionFixture()
            let draft = ReviewedTransfer(wallet: current.wallet, recipient: current.recipient, amount: current.amount,
                fee: current.fee, total: current.total, expiry: current.expiry, reviewedAt: Date().addingTimeInterval(-86_400),
                content: current.content, operationID: current.operationID, recipientCredit: current.recipientCredit)
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = FileTransferJournal(url: directory.appending(path: "isolated.json"))
            try journal.write([PendingTransfer(draft: draft, state: outcome, tracking: .historicalNodeReport)])
            let transport = TrustedResolutionTransport(draft, signature: signature, states: [outcome], version: "MAIN.5.1")
            let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
            coordinator.select(draft.wallet)
            XCTAssertNotNil(coordinator.unresolved(draft.wallet)); XCTAssertTrue(coordinator.beginNewTransfer(for: draft.wallet))
            XCTAssertNil(coordinator.recentUnresolvedOperationID)
            await coordinator.pollRecentOperation(draft.operationID) { XCTFail("Old intents must not be automatically polled") }
            let beforeManual = await transport.reads; XCTAssertEqual(beforeManual, 0)
            await coordinator.reconcile(try XCTUnwrap(coordinator.unresolved(draft.wallet)))
            XCTAssertNil(coordinator.unresolved(draft.wallet)); XCTAssertTrue(try journal.read().first?.hasTrustedResolution == true)
            XCTAssertTrue(SendStatusPresentation.evidenceMessage(coordinator.pending.first).contains(L("Confirmed by Massa Mainnet RPC")))
            let restarted = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
            restarted.select(draft.wallet); restarted.invalidateReview(); restarted.select(nil); restarted.select(draft.wallet)
            XCTAssertTrue(restarted.beginNewTransfer(for: draft.wallet)); XCTAssertEqual(restarted.phase, .draft)
            await restarted.prepare(wallet: draft.wallet, recipient: draft.recipient, amount: draft.amount.text)
            XCTAssertEqual(restarted.phase, .review)
            XCTAssertNotEqual(restarted.review?.operationID, draft.operationID)
            XCTAssertEqual(try journal.read().first?.draft, draft)
            let writes = await transport.writes; XCTAssertEqual(writes, 0, "New review does not authenticate or submit")
        }
    }
    func testRecoveryTextNeverConfirmsUnresolvedOrMalformedTrustedLabels() throws {
        let (draft, _) = try resolutionFixture()
        let malformed = ReconciliationAssessment(state: .outcomeUnknown, reason: .trustedMassaLabs, checkedAt: Date(), reportedFinalPeriod: nil)
        for record in [PendingTransfer(draft: draft, state: .outcomeUnknown), PendingTransfer(draft: draft, state: .outcomeUnknown, assessment: malformed)] {
            XCTAssertEqual(SendStatusPresentation.evidenceMessage(record), L("Not yet confirmed by Massa Mainnet RPC."))
            XCTAssertFalse(record.hasTrustedResolution)
        }
    }
    func testRecentPollingIsBoundedReadOnlyAndOldPrunedIntentNeverUnlocks() async throws {
        let (draft, signature) = try resolutionFixture()
        let transport = TrustedResolutionTransport(draft, signature: signature, states: [.outcomeUnknown])
        let journal = ResolutionJournal(PendingTransfer(draft: draft, state: .outcomeUnknown))
        let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
        coordinator.select(draft.wallet); var pauses = 0
        await coordinator.pollRecentOperation(draft.operationID) { pauses += 1 }
        XCTAssertEqual(pauses, 3); XCTAssertNotNil(coordinator.unresolved(draft.wallet))
        XCTAssertTrue(coordinator.beginNewTransfer(for: draft.wallet)); XCTAssertNil(coordinator.failure)
        let reads = await transport.reads, writes = await transport.writes
        XCTAssertEqual(reads, 8); XCTAssertEqual(writes, 0)
        XCTAssertFalse(SendStatusPresentation.evidenceMessage(coordinator.pending.first).contains(L("Confirmed by Massa Mainnet RPC")))
        let otherAccount = MassaTestAccount(), identity = try otherAccount.publicAccount
        let other = try SendWallet(ManagedWallet(id: UUID().uuidString, name: "Other disposable", address: identity.address,
            publicKey: identity.publicKey, kind: .owned, network: "Mainnet", backupAcknowledged: false))
        coordinator.select(other); XCTAssertTrue(coordinator.beginNewTransfer(for: other))
        await coordinator.prepare(wallet: other, recipient: draft.recipient, amount: "1")
        XCTAssertEqual(coordinator.phase, .review); XCTAssertNotNil(coordinator.unresolved(draft.wallet))
        coordinator.select(draft.wallet); XCTAssertNotNil(coordinator.unresolved(draft.wallet)); XCTAssertNil(coordinator.review)
    }
    func testRecentPollingCollectsReceiptOrStopsOnCancellationAndSelectionChange() async throws {
        for mode in ["final", "cancel", "selection"] {
            let (draft, signature) = try resolutionFixture()
            let states: [SubmissionState] = mode == "final" ? [.pending, .pending, .finalized] : [.outcomeUnknown]
            let transport = TrustedResolutionTransport(draft, signature: signature, states: states)
            let journal = ResolutionJournal(PendingTransfer(draft: draft, state: .outcomeUnknown))
            let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
            coordinator.select(draft.wallet)
            await coordinator.pollRecentOperation(draft.operationID) {
                if mode == "cancel" { throw CancellationError() }
                if mode == "selection" { coordinator.select(nil) }
            }
            XCTAssertEqual(coordinator.unresolved(draft.wallet) == nil, mode == "final")
            let reads = await transport.reads, writes = await transport.writes
            XCTAssertEqual(reads, mode == "final" ? 4 : 2); XCTAssertEqual(writes, 0)
        }
    }
}

@MainActor extension TransferRPCTests {
    func testCancelledForegroundReconciliationLeavesOriginalLockedWithoutSpuriousFailure() async throws {
        let (draft, signature) = try resolutionFixture()
        let transport = TrustedResolutionTransport(draft, signature: signature, mode: "delay")
        let journal = ResolutionJournal(PendingTransfer(draft: draft, state: .outcomeUnknown))
        let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
        coordinator.select(draft.wallet)
        let task = Task { await coordinator.pollRecentOperation(draft.operationID) }
        for _ in 0..<100 { if await transport.reads > 0 { break }; await Task.yield() }
        task.cancel(); await task.value
        XCTAssertNil(coordinator.failure); XCTAssertNotNil(coordinator.unresolved(draft.wallet))
        XCTAssertEqual(journal.records.first?.draft, draft); XCTAssertFalse(journal.records.first?.hasTrustedResolution ?? true)
        let writes = await transport.writes; XCTAssertEqual(writes, 0)
        coordinator.invalidateReview(); coordinator.select(nil); coordinator.select(draft.wallet)
        XCTAssertTrue(coordinator.beginNewTransfer(for: draft.wallet))
    }
}

/// Disposable generated accounts and injected transport only. Never queries a real address.
private actor HistoricalFixtureTransport: RPCTransport {
    let draft: ReviewedTransfer
    let signature: String
    let mode: String
    let version: String
    private(set) var reads = 0
    init(_ draft: ReviewedTransfer, signature: String, mode: String = "valid", version: String = "MAIN.5.1") {
        self.draft = draft; self.signature = signature; self.mode = mode; self.version = version
    }
    func send(_ request: URLRequest) async throws -> RPCTransportResponse {
        if mode == "offline" { throw URLError(.notConnectedToInternet) }
        let result: Any
        if request.httpMethod == "POST" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            guard request.url?.absoluteString == TrustedMassaRPCResolution.endpoint, body["method"] as? String == "get_status" else { XCTFail("No writes allowed"); throw SendFailure.response }
            result = ["jsonrpc": "2.0", "id": body["id"]!, "result": ["chain_id": mode == "chain" ? 1 : 77658377,
                "version": version, "current_time": UInt64(Date().timeIntervalSince1970 * 1000)]] as [String: Any]
        } else {
            XCTAssertEqual(request.url?.host, "explorer-api.massa.net"); XCTAssertEqual(request.value(forHTTPHeaderField: "x-network"), "mainnet")
            let changed = mode == "changedAfterAuth" && reads >= (request.url!.path.hasPrefix("/operation/") ? 2 : 3)
            let block = try MassaCodec.encode(Data(repeating: changed ? 88 : 87, count: 32), prefix: "B")
            let timestamp = String(UInt64(Date().timeIntervalSince1970 / 86_400) * 86_400_000 - 86_400_000)
            if request.url!.path.hasPrefix("/operation/") {
                reads += 1
                var row = TrustedRPCFixture.operation(draft, signature: signature, state: .finalized)
                row["in_blocks"] = mode == "duplicateBlock" ? [block, block] : [block]
                row["thread"] = 3; row["timestamp"] = timestamp
                row["in_pool"] = true // Captured Explorer metadata can outlive actual pool membership.
                var signed = row["operation"] as! [String: Any], content = signed["content"] as! [String: Any]
                content["fee"] = String(draft.fee.nano)
                content["op"] = ["Transaction": ["recipient_address": draft.recipient, "amount": String(draft.amount.nano)]]
                switch mode {
                case "wrongID": row["id"] = block
                case "source": signed["content_creator_address"] = draft.recipient
                case "recipient": content["op"] = ["Transaction": ["recipient_address": draft.wallet.address, "amount": draft.amount.text]]
                case "amount": content["op"] = ["Transaction": ["recipient_address": draft.recipient, "amount": "9"]]
                case "fee": content["fee"] = "0.9"
                case "signature": signed["signature"] = "bad"
                case "failed": row["op_exec_status"] = false
                case "pending": row["is_operation_final"] = false
                case "nullOutcome": row["op_exec_status"] = NSNull()
                default: break
                }
                // The real Explorer uses null entries for inactive operation variants.
                var variants = content["op"] as! [String: Any]
                for key in ["RollBuy", "RollSell", "ExecuteSC", "CallSC"] { variants[key] = NSNull() }
                content["op"] = variants; signed["content"] = content; row["operation"] = signed
                result = row
            } else {
                let item: [String: Any] = ["hash": draft.operationID, "status": "Final", "type": "Transaction", "from": draft.wallet.address,
                    "to": draft.recipient, "value": String(draft.amount.nano), "transaction_fee": String(draft.fee.nano), "op_exec_status": true]
                result = ["block": ["hash": block, "is_final": mode != "candidateBlock", "period": draft.expiry - 1,
                    "thread": 3, "block_time": timestamp, "latest_ops": mode == "missingMembership" ? [] : mode == "duplicateRow" ? [item,item] : [item]]] as [String: Any]
            }
        }
        return RPCTransportResponse(data: try JSONSerialization.data(withJSONObject: result), statusCode: 200, contentType: "application/json")
    }
}
// Legacy receipt construction is test-only. The app no longer fetches or accepts historical results.
protocol HistoricalEvidenceReading: Sendable { func evidence(for draft: ReviewedTransfer) async throws -> HistoricalEvidence }
struct OfficialHistoricalClient: HistoricalEvidenceReading {
    private let transport: any RPCTransport
    init(transport: any RPCTransport = MainnetURLSessionTransport()) { self.transport = transport }
    private struct Status: Decodable { let chain_id: UInt64; let version: String; let current_time: UInt64 }
    private struct Envelope: Decodable { let jsonrpc: String; let id: String; let result: Status?; let error: RPCError?
        struct RPCError: Decodable { let code: Int }
    }
    private func status() async throws -> Status {
        let id = UUID().uuidString
        var request = URLRequest(url: MassaEnvironment.mainnet.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TransferRequest(id: id, method: "get_status", params: [String]()))
        let response = try await transport.send(request)
        guard response.statusCode == 200, response.data.count <= 1_048_576 else { throw SendFailure.historicalEvidence }
        let envelope = try JSONDecoder().decode(Envelope.self, from: response.data)
        guard envelope.jsonrpc == "2.0", envelope.id == id, envelope.error == nil, let value = envelope.result,
              value.chain_id == MassaEnvironment.mainnet.chainID, MainnetProtocolCompatibility.supports(value.version),
              abs(Date().timeIntervalSince1970 - Double(value.current_time) / 1000) <= 20 else { throw SendFailure.historicalEvidence }
        return value
    }
    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: URL(string: HistoricalEvidence.endpoint + path)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"; request.setValue("mainnet", forHTTPHeaderField: "x-network"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.send(request)
        guard response.statusCode == 200, response.data.count <= 1_048_576,
              response.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw SendFailure.historicalEvidence }
        return try JSONDecoder().decode(T.self, from: response.data)
    }
    func evidence(for draft: ReviewedTransfer) async throws -> HistoricalEvidence {
        try draft.validate()
        let started = Date(), chain = try await status()
        var reports: [HistoricalEvidence.Report] = []
        for _ in 0..<2 {
            try Task.checkCancellation()
            let operation: HistoricalEvidence.Operation = try await get("/operation/" + draft.operationID)
            try operation.validate(for: draft)
            // Bounded first-page membership. Missing/large/unrecognized responses never authorize recovery.
            let block: HistoricalEvidence.BlockEnvelope = try await get("/block/" + operation.in_blocks[0] + "?page=0")
            try block.block.validate(for: draft, operation: operation)
            reports.append(.init(endpoint: HistoricalEvidence.endpoint, network: "mainnet", observedAt: Date(), operation: operation, block: block.block.retainingOnly(draft.operationID)))
        }
        let end = try await status()
        guard chain.version == end.version, Date().timeIntervalSince(started) <= 60 else { throw SendFailure.historicalEvidence }
        let evidence = HistoricalEvidence(chainID: chain.chain_id, nodeVersion: chain.version, reports: reports)
        try evidence.validate(for: draft); return evidence
    }
}

@MainActor extension TransferRPCTests {
    func testLegacyHistoricalReceiptStillDecodesWithoutGatingNewSend() async throws {
        let (draft, signature) = try resolutionFixture()
        let authorized = Date()
        let evidence = try await OfficialHistoricalClient(transport: HistoricalFixtureTransport(draft, signature: signature)).evidence(for: draft)
        let receipt = OwnerHistoricalResolution(policy: OwnerHistoricalResolution.policyID, authorizationMethod: "deviceOwnerAuthentication", authorizedAt: authorized, acceptedAt: Date(), evidence: evidence)
        try receipt.validate(for: draft)
        let assessment = ReconciliationAssessment(state: .finalized, reason: .ownerReviewedHistorical, checkedAt: receipt.acceptedAt, reportedFinalPeriod: nil, reportedState: .finalized, terminalClaims: [.finalized], historicalResolution: receipt)
        let record = PendingTransfer(draft: draft, state: .finalized, assessment: assessment)
        let decoded = try JSONDecoder().decode(PendingTransfer.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record); XCTAssertTrue(decoded.hasTrustedResolution)
        let journal = ResolutionJournal(decoded)
        let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: TransferTransport()), journal: journal)
        coordinator.select(draft.wallet); XCTAssertNil(coordinator.review); XCTAssertEqual(coordinator.phase, .draft)
        XCTAssertTrue(coordinator.beginNewTransfer(for: draft.wallet))
        await coordinator.prepare(wallet: draft.wallet, recipient: draft.recipient, amount: "2")
        XCTAssertEqual(coordinator.phase, .review); XCTAssertEqual(coordinator.pending.first?.draft, decoded.draft); XCTAssertEqual(coordinator.pending.first?.assessment, decoded.assessment)
    }
    func testLegacyHistoricalReceiptValidationRejectsAlteredEvidence() async throws {
        for mode in ["wrongID","source","recipient","amount","fee","signature","failed","pending","nullOutcome","candidateBlock","missingMembership","duplicateBlock","duplicateRow","chain","offline"] {
            let (draft, signature) = try resolutionFixture()
            do { _ = try await OfficialHistoricalClient(transport: HistoricalFixtureTransport(draft, signature: signature, mode: mode)).evidence(for: draft); XCTFail(mode) }
            catch { /* Invalid legacy receipts cannot establish final execution. */ }
        }
    }
}
