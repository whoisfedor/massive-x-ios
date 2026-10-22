import XCTest
@testable import MassiveX

private struct StreamResponse: Sendable {
    let headers: [String: String]
    let chunk: Data
    let count: Int
}
private final class StreamFixture: @unchecked Sendable {
    enum Mode: Sendable { case declared, absent, dishonest, decodedGzip, small, interruptedSubmit }
    let mode: Mode
    private let lock = NSLock()
    private var sent = 0, stopped = 0
    var counts: (sent: Int, stopped: Int) { lock.withLock { (sent, stopped) } }
    init(_ mode: Mode) { self.mode = mode }
    func delivered() { lock.withLock { sent += 1 } }
    func cancelled() { lock.withLock { stopped += 1 } }
    func response(_ request: URLRequest) throws -> StreamResponse {
        if mode == .small { return StreamResponse(headers: ["Content-Type": "application/json"], chunk: Data("[]".utf8), count: 1) }
        if mode == .interruptedSubmit {
            var requestData = request.httpBody ?? Data()
            if requestData.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0, requestData.count + count <= 65_536 else { throw SendFailure.response }
                    if count == 0 { break }; requestData.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try JSONSerialization.jsonObject(with: requestData) as! [String: Any]
            let method = body["method"] as! String, result: Any
            if method == "get_status" {
                result = ["chain_id": 77658377, "version": "MAIN.5.0", "last_slot": ["period": 100], "minimal_fees": "0.01", "current_time": UInt64(Date().timeIntervalSince1970 * 1000), "config": ["operation_validity_periods": 10]] as [String: Any]
            } else if method == "get_addresses" {
                result = (body["params"] as! [[String]])[0].map { ["address": $0, "final_balance": "10", "candidate_balance": "10"] }
            } else if method == "get_operations" { result = [] as [String] }
            else if method == "send_operations" { return StreamResponse(headers: ["Content-Type": "application/json"], chunk: Data(repeating: 32, count: 65_536), count: 64) }
            else { throw SendFailure.response }
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": body["id"]!, "result": result])
            return StreamResponse(headers: ["Content-Type": "application/json"], chunk: data, count: 1)
        }
        var headers = ["Content-Type": "application/json"]
        if mode == .declared { headers["Content-Length"] = "99999999" }
        if mode == .dishonest { headers["Content-Length"] = "1" }
        if mode == .decodedGzip { headers["Content-Encoding"] = "gzip"; headers["Content-Length"] = "12" }
        return StreamResponse(headers: headers, chunk: Data(repeating: 32, count: 65_536), count: 64)
    }
}
private final class StreamRouter: @unchecked Sendable {
    static let shared = StreamRouter()
    private let lock = NSLock()
    private var fixtures: [String: StreamFixture] = [:]
    func add(_ fixture: StreamFixture) -> String { lock.withLock { let id = UUID().uuidString; fixtures[id] = fixture; return id } }
    func fixture(_ request: URLRequest) -> StreamFixture? { lock.withLock { request.value(forHTTPHeaderField: "X-Isolated-Fixture").flatMap { fixtures[$0] } } }
    func remove(_ id: String) { _ = lock.withLock { fixtures.removeValue(forKey: id) } }
}
private final class StreamProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true } // This isolated configuration never escapes to a real transport.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = StreamRouter.shared.fixture(request) else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        do {
            let response = try fixture.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: response.headers)!, cacheStoragePolicy: .notAllowed)
            drip(response, fixture: fixture, index: 0)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func drip(_ response: StreamResponse, fixture: StreamFixture, index: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) { [self] in
            guard !lock.withLock({ stopped }) else { return }
            if index == response.count { client?.urlProtocolDidFinishLoading(self); return }
            fixture.delivered(); client?.urlProtocol(self, didLoad: response.chunk)
            drip(response, fixture: fixture, index: index + 1)
        }
    }
    override func stopLoading() { lock.withLock { stopped = true }; StreamRouter.shared.fixture(request)?.cancelled() }
}
private struct IsolatedStream: RPCTransport {
    let id: String
    let transport: MainnetURLSessionTransport
    init(id: String) { self.id = id; let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StreamProtocol.self]; transport = MainnetURLSessionTransport(configuration: config) }
    func send(_ request: URLRequest) async throws -> RPCTransportResponse {
        var request = request; request.setValue(id, forHTTPHeaderField: "X-Isolated-Fixture")
        return try await transport.send(request)
    }
}
@MainActor private final class StreamJournal: TransferJournal {
    let installationID: UUID? = TransferTestContinuity.id
    var records: [PendingTransfer] = []
    func read() throws -> [PendingTransfer] { records }
    func write(_ records: [PendingTransfer]) throws { self.records = records }
}
@MainActor private struct StreamSigner: TransferSigning {
    let account: MassaTestAccount
    func sign(_ draft: ReviewedTransfer) async throws -> String { try account.signOperation(draft.content, expected: account.publicAccount) }
    func cancel() {}
}
final class BoundedTransportTests: XCTestCase {
    func testDecodedBufferNeverRetainsBeyondLimit() throws {
        var buffer = HTTPBodyBuffer(limit: 1024)
        try buffer.append(Data(repeating: 1, count: 1024))
        XCTAssertThrowsError(try buffer.append(Data(repeating: 2, count: 100_000)))
        XCTAssertEqual(buffer.data.count, 1024); buffer.clear(); XCTAssertEqual(buffer.data.count, 0)
    }
    func testDeclaredAbsentMisleadingChunkedAndDecodedGzipBodiesCancelEarlyAcrossEndpoints() async throws {
        for host in ["mainnet.massa.net", "explorer-api.massa.net", "api.coingecko.com", "api.frankfurter.dev"] {
            for mode in [StreamFixture.Mode.declared, .absent, .dishonest, .decodedGzip] {
                let fixture = StreamFixture(mode), id = StreamRouter.shared.add(fixture)
                defer { StreamRouter.shared.remove(id) }
                do {
                    _ = try await IsolatedStream(id: id).send(URLRequest(url: URL(string: "https://" + host + "/fixture")!))
                    XCTFail("Oversized response accepted")
                } catch { XCTAssertEqual(error as? HTTPTransportError, .bodyTooLarge) }
                XCTAssertLessThan(fixture.counts.sent, 64)
                for _ in 0..<100 where fixture.counts.stopped == 0 { try await Task.sleep(for: .milliseconds(1)) }
                XCTAssertGreaterThan(fixture.counts.stopped, 0)
            }
        }
    }
    func testSmallResponseAndRequestCancellation() async throws {
        let small = StreamFixture(.small), id = StreamRouter.shared.add(small); defer { StreamRouter.shared.remove(id) }
        let response = try await IsolatedStream(id: id).send(URLRequest(url: MassaEnvironment.mainnet.endpoint))
        XCTAssertEqual(response.data, Data("[]".utf8))
        let large = StreamFixture(.absent), other = StreamRouter.shared.add(large); defer { StreamRouter.shared.remove(other) }
        let task = Task { try await IsolatedStream(id: other).send(URLRequest(url: MassaEnvironment.mainnet.endpoint)) }
        while large.counts.sent == 0 { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request returned a body") } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertLessThan(large.counts.sent, 64)
    }
    @MainActor func testOversizedSubmissionResponseKeepsSameOperationUnknownWithoutResend() async throws {
        let fixture = StreamFixture(.interruptedSubmit), id = StreamRouter.shared.add(fixture); defer { StreamRouter.shared.remove(id) }
        let account = MassaTestAccount(), identity = try account.publicAccount
        let wallet = try SendWallet(ManagedWallet(id: UUID().uuidString, name: "Disposable", address: identity.address, publicKey: identity.publicKey, kind: .owned, network: "Mainnet", backupAcknowledged: false, creationJournalID: TransferTestContinuity.id))
        let journal = StreamJournal(), rpc = MainnetTransferRPC(transport: IsolatedStream(id: id)), coordinator = SendCoordinator(network: rpc, journal: journal)
        coordinator.select(wallet)
        await coordinator.prepare(wallet: wallet, recipient: try MassaTestAccount().publicAccount.address, amount: "1")
        let draft = try XCTUnwrap(coordinator.review)
        await coordinator.confirm(approved: draft, signer: StreamSigner(account: account))
        XCTAssertEqual(coordinator.phase, .outcomeUnknown); XCTAssertEqual(journal.records.first?.draft.operationID, draft.operationID)
        let recovered = SendCoordinator(network: rpc, journal: journal); recovered.select(wallet)
        await recovered.reconcile(try XCTUnwrap(recovered.unresolved(wallet)))
        XCTAssertEqual(recovered.unresolved(wallet)?.draft.operationID, draft.operationID)
        await recovered.prepare(wallet: wallet, recipient: draft.recipient, amount: "1")
        XCTAssertEqual(recovered.failure, .duplicate)
    }
}
