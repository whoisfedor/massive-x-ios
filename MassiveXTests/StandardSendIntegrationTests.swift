import XCTest
import LocalAuthentication
@testable import MassiveX

@MainActor private final class StandardMemoryStore: TestAccountSecretStore {
    private let bytes: Data
    private(set) var reads = 0
    init(_ bytes: Data) { self.bytes = bytes }
    func saveNew(_ seed: Data) throws { throw SendFailure.response }
    func load(context: LAContext?) throws -> Data? {
        guard context != nil else { throw SendFailure.keyUnavailable }
        reads += 1; return bytes
    }
    func delete() throws { throw SendFailure.response }
}
@MainActor private final class StandardAuthTally { var calls = 0 }
@MainActor private struct StandardMockAuth: WalletAuthenticating {
    var tally: StandardAuthTally? = nil
    func authorize(reason: String) async throws -> LAContext { tally?.calls += 1; return LAContext() }
    func cancel() {}
}
@MainActor private struct StandardPublicMetadata: WalletMetadataStoring {
    let record: WalletRecord
    func load() -> WalletRecord? { record }
    func save(_ record: WalletRecord) {}
}
/// Does not instantiate URLSession. All RPC requests, including writes, terminate in this actor.
private actor StandardRPCMock: RPCTransport {
    let journal: FileTransferJournal
    var writes = 0
    var durableBeforeWrite = false
    var lostResponse = false
    var final = false
    var operationID: String?
    var submittedSignature: String?
    init(journal: FileTransferJournal) { self.journal = journal }
    func configure(lostResponse: Bool = false, final: Bool = false) { self.lostResponse = lostResponse; self.final = final }
    func send(_ request: URLRequest) async throws -> RPCTransportResponse {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let method = body["method"] as! String
        let result: Any
        switch method {
        case "get_status":
            result = ["chain_id": 77658377, "version": "MAIN.5.0", "current_time": UInt64(Date().timeIntervalSince1970 * 1000), "minimal_fees": "0.012345678", "last_slot": ["period": 100], "config": ["operation_validity_periods": 10]] as [String: Any]
        case "get_addresses":
            result = (body["params"] as! [[String]])[0].enumerated().map { index, address in ["address": address, "final_balance": index == 0 ? "10" : "0", "candidate_balance": index == 0 ? "9" : "0"] }
        case "send_operations":
            let inputs = body["params"] as! [[[String: Any]]]
            guard inputs.count == 1, inputs[0].count == 1 else { throw SendFailure.response }
            let input = inputs[0][0], content = Data(input["serialized_content"] as! [UInt8]), key = input["creator_public_key"] as! String
            let account = try MassaPublicAccount(rawPublicKey: MassaCodec.decode(key, prefix: "P"))
            guard try account.verify(message: MassaOperationEncoding.canonical(content: content, publicKey: key), signature: input["signature"] as! String) else { throw SendFailure.keyUnavailable }
            let id = try MassaOperationEncoding.operationID(content: content, publicKey: key)
            let records = try await journal.read()
            durableBeforeWrite = records.contains { $0.state == .submitting && $0.draft.operationID == id && $0.draft.content == content && $0.draft.wallet.address == account.address }
            guard durableBeforeWrite else { throw SendFailure.journal }
            writes += 1; operationID = id; submittedSignature = input["signature"] as? String
            if lostResponse { throw URLError(.networkConnectionLost) }
            result = [id]
        case "get_operations":
            guard let operationID, (body["params"] as! [[String]])[0] == [operationID] else { throw SendFailure.response }
            let records = try await journal.read()
            guard let draft = records.first(where: { $0.draft.operationID == operationID })?.draft, let submittedSignature else { throw SendFailure.response }
            result = [TrustedRPCFixture.operation(draft, signature: submittedSignature, state: final ? .finalized : .pending)]
        default: throw SendFailure.response
        }
        return RPCTransportResponse(data: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": body["id"]!, "result": result]), statusCode: 200, contentType: "application/json")
    }
}
@MainActor final class StandardSendIntegrationTests: XCTestCase {
    func testStandardApplicationIdentity() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Massive X")
    }
    func testActualStandardPipelineProtectedSignerDurableJournalAndMockRPC() async throws {
        try await exercise(lostResponse: false)
    }
    func testActualStandardPipelineLostResponseRestartAndNoResend() async throws {
        try await exercise(lostResponse: true)
    }
    func testPrePatchOwnedWalletWithoutCreationBindingUsesProtectedStandardPipeline() async throws {
        try await exercise(lostResponse: false, sourceKind: "legacy")
    }
    func testImportedUnfundedTestKeyWithMockFundedBalanceUsesProtectedStandardPipeline() async throws {
        try await exercise(lostResponse: false, sourceKind: "imported")
    }
    func testReimportWithFreshInstallationAndNoPriorJournalCanApproveNewIntent() async throws {
        try await exercise(lostResponse: false, sourceKind: "reinstall")
    }
    func testSlideRequiresFullCommitThenExactlyOneProtectedAuthenticationAndSubmission() async throws {
        try await exercise(lostResponse: true, useSlide: true)
    }
    private func exercise(lostResponse: Bool, sourceKind: String = "generated", useSlide: Bool = false) async throws {
        // Disposable, unfunded, memory-only key. No system Keychain, operator wallet or live transport.
        let generated = MassaTestAccount()
        let account = try sourceKind == "imported" ? MassaTestAccount(importing: generated.backupPrivateKeyEncoding()) : generated
        let identity = try account.publicAccount
        var metadata = ManagedWallet(id: UUID().uuidString, name: "Disposable integration", address: identity.address, publicKey: identity.publicKey, kind: .owned, network: "Mainnet", backupAcknowledged: true,
                                     creationJournalID: sourceKind == "generated" ? TransferTestContinuity.id : nil)
        if sourceKind == "legacy" {
            var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as! [String: Any]
            old.removeValue(forKey: "creationJournalID")
            metadata = try JSONDecoder().decode(ManagedWallet.self, from: JSONSerialization.data(withJSONObject: old))
        }
        let wallet = try SendWallet(metadata)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = FileTransferJournal(url: directory.appending(path: "pending.json"), initialIdentity: TransferTestContinuity.id), transport = StandardRPCMock(journal: journal)
        await transport.configure(lostResponse: lostResponse)
        let client = MainnetTransferRPC(transport: transport), coordinator = SendCoordinator(network: client, journal: journal)
        let store = StandardMemoryStore(account.storageData())
        let auth = StandardAuthTally()
        let access = WalletOnboarding(store: store, authentication: StandardMockAuth(tally: auth), metadata: StandardPublicMetadata(record: WalletRecord(identity)))
        access.updatePrivacy(active: true, captured: false)
        coordinator.select(wallet)
        await coordinator.prepare(wallet: wallet, recipient: try MassaTestAccount().publicAccount.address, amount: "1.123456789")
        let approved = try XCTUnwrap(coordinator.review)
        XCTAssertEqual(store.reads, 0); XCTAssertEqual(auth.calls, 0)
        XCTAssertEqual(coordinator.hasCreationBinding(wallet), sourceKind == "generated")
        XCTAssertEqual(approved.total.text, "1.135802467")
        XCTAssertEqual(approved.recipientCredit?.minimum.text, "1.122456789")
        XCTAssertEqual(approved.recipientCredit?.creationPossible, true)
        if useSlide {
            var slider = SlideSubmissionState()
            slider.update(horizontal: 90, vertical: 0, travel: 200)
            XCTAssertFalse(slider.finish(enabled: true)); XCTAssertEqual(auth.calls, 0); XCTAssertEqual(store.reads, 0)
            let before = await transport.writes; XCTAssertEqual(before, 0)
            slider.update(horizontal: 200, vertical: 0, travel: 200)
            XCTAssertTrue(slider.finish(enabled: true))
            XCTAssertFalse(slider.finish(enabled: true)); XCTAssertFalse(slider.accessibleCommit(enabled: true))
        }
        await coordinator.confirm(approved: approved, signer: ProtectedTransferSigner(access: access))
        XCTAssertEqual(store.reads, 1); XCTAssertEqual(auth.calls, 1); XCTAssertNil(access.revealedKey); XCTAssertFalse(access.isRevealed)
        let persisted = await transport.durableBeforeWrite; XCTAssertTrue(persisted)
        XCTAssertEqual(coordinator.phase, lostResponse ? .outcomeUnknown : .pending)
        let recovered = SendCoordinator(network: client, journal: journal); recovered.select(wallet)
        XCTAssertNotNil(recovered.unresolved(wallet))
        await recovered.prepare(wallet: wallet, recipient: approved.recipient, amount: approved.amount.text)
        XCTAssertEqual(recovered.failure, .alreadyRecorded)
        await transport.configure(final: true)
        await recovered.reconcile(try XCTUnwrap(try journal.read().first))
        XCTAssertEqual(recovered.phase, .draft); XCTAssertNil(recovered.unresolved(wallet)); XCTAssertEqual(recovered.failure, .alreadyRecorded)
        XCTAssertTrue(try journal.read().first?.hasTrustedResolution ?? false)
        let restart = SendCoordinator(network: client, journal: journal); restart.select(wallet)
        XCTAssertNil(restart.unresolved(wallet))
        let before = await transport.writes; XCTAssertEqual(before, 1)
        await transport.configure(lostResponse: false)
        await restart.prepare(wallet: wallet, recipient: approved.recipient, amount: "2")
        let second = try XCTUnwrap(restart.review); XCTAssertNotEqual(second.operationID, approved.operationID)
        XCTAssertEqual(auth.calls, 1); XCTAssertEqual(store.reads, 1)
        // The real confirmation button restores foreground privacy before EACH protected authorization.
        access.updatePrivacy(active: true, captured: false)
        await restart.confirm(approved: second, signer: ProtectedTransferSigner(access: access))
        XCTAssertEqual(auth.calls, 2); XCTAssertEqual(store.reads, 2)
        XCTAssertNil(access.revealedKey); XCTAssertEqual(restart.phase, .pending)
        XCTAssertEqual(try journal.read().count, 2)
        let writes = await transport.writes; XCTAssertEqual(writes, 2)
    }
}


extension StandardSendIntegrationTests {
    func testChangedContinuityAndHistoricalStringsExistInAllSixBuiltLocalizations() throws {
        let keys = ["Confirmed by Massa Mainnet RPC",
                    "Confirmed by Massa Mainnet RPC. This relies on the Massa Labs provider, not independent cryptographic verification.",
                    "The stored terminal report has not passed the Massa Labs RPC checks. Keep this payment locked until its original operation can be checked.",
                    "Massive X trusts the official Massa Labs Mainnet RPC for validated final execution outcomes. This is not independent cryptographic verification. Missing or contradictory results remain locked; never repeat a payment because a lookup is empty.",
                    "This installation may not contain earlier payments. Importing a key or changing devices does not recover missing operation records. Check your previous wallet and records before making a new payment; never repeat an uncertain payment.",
                    "A local journal UUID is integrity metadata, not permission to spend or proof of complete history. New payments always require a fresh review and protected authorization.",
                    "This wallet has a recorded payment intent with an unverified outcome. New payments stay locked for this source. Keep the original records; do not repeat the payment.",
                    "Local submission intent · Locked",
                    "Wallet added. Save a private backup before relying on it."]
        for language in AppLanguage.allCases {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let text = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
                XCTAssertNotEqual(text, "MISSING")
                if language != .english { XCTAssertNotEqual(text, key) }
            }
        }
    }
}
