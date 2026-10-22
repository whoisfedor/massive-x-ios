import XCTest
import UIKit
import CoreImage

@testable import MassiveX

private struct Transport: RPCTransport {
    enum Mode: Sendable { case success, wrongNetwork, wrongID, rpc, http, offline, timeout, malformed, precision, addressMismatch, both, oversized, cancelled }
    let mode: Mode
    func send(_ request: URLRequest) async throws -> RPCTransportResponse {
        XCTAssertEqual(request.url, MassaEnvironment.mainnet.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 15)
        if mode == .cancelled { throw CancellationError() }
        if mode == .offline { throw URLError(.notConnectedToInternet) }
        if mode == .timeout { throw URLError(.timedOut) }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let method = body["method"] as! String
        XCTAssertTrue(["get_status", "get_addresses"].contains(method))
        var envelope: [String: Any] = ["jsonrpc": "2.0", "id": mode == .wrongID ? "wrong" : body["id"]!]
        if mode == .rpc { envelope["error"] = ["code": -32603, "message": "Untrusted server text"] }
        else if method == "get_status" {
            envelope["result"] = ["version": "MAIN.5.0", "chain_id": mode == .wrongNetwork ? 1 : 77658377, "current_cycle": 42]
        } else {
            let address = (body["params"] as! [[String]])[0][0]
            envelope["result"] = [["address": mode == .addressMismatch ? "wrong" : address, "final_balance": "0", "candidate_balance": mode == .precision ? "1.1234567890" : "0.123456789"]]
        }
        if mode == .both { envelope["error"] = ["code": -1] }
        if mode == .oversized { return RPCTransportResponse(data: Data(count: 1_048_577), statusCode: 200) }
        return RPCTransportResponse(data: mode == .malformed ? Data("broken".utf8) : try JSONSerialization.data(withJSONObject: envelope), statusCode: mode == .http ? 503 : 200)
    }
}

final class MainnetTests: XCTestCase {
    func testStatusAndBalanceDecoding() async throws {
        let client = MainnetRPC(transport: Transport(mode: .success))
        let status = try await client.status()
        XCTAssertEqual(status.chainID, 77658377)
        let address = try MassaTestAccount(seed: Data(repeating: 0, count: 32)).publicAccount.address
        let balance = try await client.balance(for: address)
        XCTAssertEqual(balance.finalBalance, "0")
        XCTAssertEqual(balance.candidateBalance, "0.123456789")
    }
    func testErrorsFailClosed() async {
        let cases: [(Transport.Mode, MainnetRPCError)] = [(.wrongNetwork, .wrongNetwork), (.wrongID, .invalidResponse), (.rpc, .rpc(-32603)), (.http, .http(503)), (.offline, .offline), (.timeout, .timedOut), (.malformed, .invalidResponse), (.both, .invalidResponse), (.oversized, .invalidResponse), (.cancelled, .cancelled)]
        for (mode, expected) in cases {
            do { _ = try await MainnetRPC(transport: Transport(mode: mode)).status(); XCTFail("Unexpected acceptance") }
            catch { XCTAssertEqual(error as? MainnetRPCError, expected) }
        }
    }
    func testInvalidAddressAndAmountsRejected() async throws {
        let client = MainnetRPC(transport: Transport(mode: .precision))
        for address in ["not-an-address", try MassaTestAccount(seed: Data(repeating: 0, count: 32)).publicAccount.address] {
            do { _ = try await client.balance(for: address); XCTFail("Unexpected acceptance") }
            catch { XCTAssertEqual(error as? MainnetRPCError, address == "not-an-address" ? .invalidAddress : .invalidResponse) }
        }
    }
    func testAccountQueriesRejectWrongNetworkAndAddress() async throws {
        let address = try MassaTestAccount(seed: Data(repeating: 0, count: 32)).publicAccount.address
        for (mode, expected): (Transport.Mode, MainnetRPCError) in [(.wrongNetwork, .wrongNetwork), (.addressMismatch, .invalidResponse)] {
            do { _ = try await MainnetRPC(transport: Transport(mode: mode)).balance(for: address); XCTFail("Unexpected acceptance") }
            catch { XCTAssertEqual(error as? MainnetRPCError, expected) }
        }
    }
    func testBalanceAmountsAreCanonicalDecimals() {
        for amount in ["1\n", "-1", "+1", "01", "1e3", "NaN", "1.", ".1", "1.1234567890"] {
            XCTAssertFalse(MainnetBalance(address: "test", finalBalance: amount, candidateBalance: "0").hasValidAmounts)
        }
        for amount in ["0", "1", "123.123456789"] {
            XCTAssertTrue(MainnetBalance(address: "test", finalBalance: amount, candidateBalance: "0").hasValidAmounts)
        }
    }
    @MainActor func testUIStateSuccessAndFailure() async {
        let success = MainnetState(client: MainnetRPC(transport: Transport(mode: .success)))
        XCTAssertEqual(success.phase, .idle)
        await success.refresh()
        XCTAssertEqual(success.phase, .connected(MainnetStatus(version: "MAIN.5.0", chainID: 77658377, currentCycle: 42)))
        let failure = MainnetState(client: MainnetRPC(transport: Transport(mode: .offline)))
        await failure.refresh()
        XCTAssertEqual(failure.phase, .unavailable(MainnetRPCError.offline.userMessage))
    }
}

private actor RetryTransport: RPCTransport {
    var calls = 0
    let alwaysLimited: Bool
    init(alwaysLimited: Bool) { self.alwaysLimited = alwaysLimited }
    func send(_ request: URLRequest) async throws -> RPCTransportResponse {
        calls += 1
        XCTAssertEqual(request.url?.absoluteString, "https://mainnet.massa.net/api/v2")
        if calls == 1 || alwaysLimited { return RPCTransportResponse(data: Data(), statusCode: 429) }
        let requestBody = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        return RPCTransportResponse(data: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": requestBody["id"]!, "result": ["version": "MAIN.5.0", "chain_id": 77658377, "current_cycle": 42528]]), statusCode: 200)
    }
}

extension MainnetTests {
    func testOnlyMainnetAndOnlyReadMethodsWithBoundedRetry() async throws {
        XCTAssertEqual(MassaEnvironment.allCases, [.mainnet])
        XCTAssertEqual(Set(MainnetRPC.ReadMethod.allCases.map(\.rawValue)), ["get_status", "get_addresses"])
        let transport = RetryTransport(alwaysLimited: false)
        _ = try await MainnetRPC(transport: transport).status()
        let calls = await transport.calls; XCTAssertEqual(calls, 2)
        let limited = RetryTransport(alwaysLimited: true)
        do { _ = try await MainnetRPC(transport: limited).status(); XCTFail("Expected rate-limit state") }
        catch { XCTAssertEqual(error as? MainnetRPCError, .rateLimited) }
        let limitedCalls = await limited.calls; XCTAssertEqual(limitedCalls, 2)
    }
    @MainActor func testReceivePayloadAndCopyContainOnlySelectedPublicAddress() throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let first = try MassaTestAccount().publicAccount, second = try MassaTestAccount().publicAccount
        let owned = ManagedWallet(id: UUID().uuidString, name: "Test only", address: first.address, publicKey: first.publicKey,
            kind: .owned, network: "Mainnet", backupAcknowledged: false)
        let watch = ManagedWallet(id: UUID().uuidString, name: "Observer", address: second.address, publicKey: nil,
            kind: .watchOnly, network: "Mainnet", backupAcknowledged: false)
        let a = try ReceivePayload(wallet: owned), b = try ReceivePayload(wallet: watch)
        XCTAssertTrue(a.qrData == Data(first.address.utf8)); XCTAssertTrue(b.qrData == Data(second.address.utf8))
        let image = try XCTUnwrap(ReceiveView.makeQR(a.qrData))
        let cg = try XCTUnwrap(image.cgImage)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let feature = try XCTUnwrap(detector.features(in: CIImage(cgImage: cg)).first as? CIQRCodeFeature)
        XCTAssertTrue(feature.messageString == first.address)
        a.copyAddress(to: board); XCTAssertTrue(board.string == first.address)
        b.copyAddress(to: board); XCTAssertTrue(board.string == second.address)
        var archived = owned; archived.safety = .archivedPreview
        XCTAssertThrowsError(try ReceivePayload(wallet: archived))
    }
}
