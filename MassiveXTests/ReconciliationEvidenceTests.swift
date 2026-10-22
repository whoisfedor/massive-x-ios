import XCTest
@testable import MassiveX

private actor EvidenceTransport: RPCTransport {
    let states: [SubmissionState]
    let finalPeriod: UInt64
    var reads = 0, writes = 0
    init(_ states: [SubmissionState], finalPeriod: UInt64) { self.states = states; self.finalPeriod = finalPeriod }
    func send(_ request: URLRequest) async throws -> RPCTransportResponse {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let method = body["method"] as! String, result: Any
        if method == "get_status" {
            result = ["chain_id": 77658377, "version": "MAIN.5.0", "last_slot": ["period": 200], "minimal_fees": "0.01", "current_time": UInt64(Date().timeIntervalSince1970 * 1000), "config": ["operation_validity_periods": 10], "execution_stats": ["final_cursor": ["period": finalPeriod]]] as [String: Any]
        } else if method == "get_operations" {
            let state = states[min(reads, states.count - 1)]; reads += 1
            let id = (body["params"] as! [[String]])[0][0]
            if state == .outcomeUnknown { result = [] as [String] }
            else { result = [["id": id, "in_pool": state == .pending, "is_operation_final": state == .finalized || state == .failed, "op_exec_status": state == .pending ? NSNull() : state == .finalized]] as [[String: Any]] }
        } else { writes += 1; XCTFail("No write is allowed in evidence tests"); throw SendFailure.response }
        return RPCTransportResponse(data: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": body["id"]!, "result": result]), statusCode: 200)
    }
}
@MainActor private final class EvidenceJournal: TransferJournal {
    var records: [PendingTransfer]
    init(_ record: PendingTransfer) { records = [record] }
    func read() throws -> [PendingTransfer] { records }
    func write(_ records: [PendingTransfer]) throws { self.records = records }
}
@MainActor final class ReconciliationEvidenceTests: XCTestCase {
    private func record() throws -> PendingTransfer {
        let identity = try MassaPublicAccount(rawPublicKey: Data(repeating: 41, count: 32))
        let wallet = try SendWallet(ManagedWallet(id: UUID().uuidString, name: "Public fixture", address: identity.address, publicKey: identity.publicKey, kind: .owned, network: "Mainnet", backupAcknowledged: false))
        let now = Date(), snapshot = SendSnapshot(fetched: now, chainID: 77658377, period: 100, validity: 10, fee: MASAmount(nano: 1), finalBalance: MASAmount(nano: 10), candidateBalance: MASAmount(nano: 10), recipientFinal: MASAmount(nano: 1), recipientCandidate: MASAmount(nano: 1))
        return try PendingTransfer(draft: ReviewedTransfer.make(wallet: wallet, recipient: wallet.address, amount: "0.000000001", snapshot: snapshot, now: now), state: .outcomeUnknown)
    }
    func testNeverAcceptedAndAcceptedButPrunedRemainIndistinguishableAndLocked() async throws {
        for finalPeriod: UInt64 in [108, 110, 200] {
            let original = try record(), journal = EvidenceJournal(original), transport = EvidenceTransport([.outcomeUnknown], finalPeriod: finalPeriod)
            let rpc = MainnetTransferRPC(transport: transport), coordinator = SendCoordinator(network: rpc, journal: journal)
            coordinator.select(original.draft.wallet); await coordinator.reconcile(original)
            let result = try XCTUnwrap(coordinator.unresolved(original.draft.wallet))
            XCTAssertEqual(result.draft, original.draft); XCTAssertEqual(result.state, .outcomeUnknown)
            XCTAssertEqual(result.assessment?.reason, finalPeriod > original.draft.expiry ? .expiredHistoryUnavailable : .notFound)
            let restart = SendCoordinator(network: rpc, journal: journal)
            XCTAssertNotNil(restart.unresolved(original.draft.wallet))
            await restart.prepare(wallet: original.draft.wallet, recipient: original.draft.recipient, amount: original.draft.amount.text)
            XCTAssertEqual(restart.failure, .duplicate)
            let writes = await transport.writes; XCTAssertEqual(writes, 0)
        }
    }
    func testTerminalFlagsWithoutCanonicalContentCannotUnlockOrInventFailure() async throws {
        let original = try record(), journal = EvidenceJournal(original), transport = EvidenceTransport([.finalized, .failed], finalPeriod: 200)
        let coordinator = SendCoordinator(network: MainnetTransferRPC(transport: transport), journal: journal)
        coordinator.select(original.draft.wallet); await coordinator.reconcile(original)
        XCTAssertNotNil(coordinator.unresolved(original.draft.wallet)); XCTAssertEqual(coordinator.failure, .response)
        XCTAssertEqual(coordinator.phase, .outcomeUnknown)
    }
    func testMatchingFinalSuccessFailureAndSpeculativeStatusesRemainDistinct() async throws {
        for state in [SubmissionState.finalized, .failed, .pending] {
            let original = try record(), journal = EvidenceJournal(original), rpc = MainnetTransferRPC(transport: EvidenceTransport([state], finalPeriod: 200))
            let coordinator = SendCoordinator(network: rpc, journal: journal)
            coordinator.select(original.draft.wallet); await coordinator.reconcile(original)
            XCTAssertEqual(journal.records.first?.state, state == .pending ? .pending : .outcomeUnknown)
            if state == .pending { XCTAssertEqual(journal.records.first?.assessment?.reportedState, state) }
            else { XCTAssertNil(journal.records.first?.assessment?.providerResolution); XCTAssertEqual(coordinator.failure, .response) }
            XCTAssertNotNil(coordinator.unresolved(original.draft.wallet))
        }
    }
    func testSupportDetailsContainOriginalIdentityButNeverClaimPaymentProof() throws {
        let original = try record(), coordinator = SendCoordinator(network: MainnetTransferRPC(transport: EvidenceTransport([.outcomeUnknown], finalPeriod: 200)), journal: EvidenceJournal(original))
        let details = coordinator.supportDetails(original)
        XCTAssertTrue(details.contains(original.draft.operationID))
        XCTAssertTrue(details.contains("not independently established")); XCTAssertFalse(details.contains("signature"))
        XCTAssertFalse(details.contains(original.draft.wallet.publicKey))
    }
}
