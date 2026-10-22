import Foundation

/// No configurable URL, alternate network, private API or write methods are exposed.
enum MassaEnvironment: String, CaseIterable, Sendable {
    case mainnet = "Mainnet"
    var endpoint: URL { URL(string: "https://mainnet.massa.net/api/v2")! }
    var chainID: UInt64 { 77_658_377 }
}

struct RPCTransportResponse: Sendable {
    let data: Data
    let statusCode: Int
    let contentType: String?
    init(data: Data, statusCode: Int, contentType: String? = nil) {
        self.data = data; self.statusCode = statusCode; self.contentType = contentType
    }
}
protocol RPCTransport: Sendable {
    func send(_ request: URLRequest) async throws -> RPCTransportResponse
}

enum MainnetRPCError: Error, Equatable {
    case offline, timedOut, rateLimited, http(Int), rpc(Int), invalidResponse, wrongNetwork, invalidAddress, cancelled
    var userMessage: String {
        switch self {
        case .offline: "No connection to Mainnet. Check your connection and retry."
        case .timedOut: "Mainnet did not respond in time. Try again."
        case .rateLimited: "Mainnet is rate limiting requests. Wait before refreshing."
        case .http: "The Mainnet service is unavailable. Try again later."
        case .rpc: "Mainnet rejected the read-only request. Try again later."
        case .wrongNetwork: "Network identity did not match Mainnet. Account queries were blocked."
        case .invalidAddress: "The Massa user address is invalid."
        case .cancelled: "The request was cancelled."
        case .invalidResponse: "Mainnet returned an unexpected response. No data was accepted."
        }
    }
}

struct MainnetStatus: Decodable, Equatable, Sendable {
    let version: String
    let chainID: UInt64
    let currentCycle: UInt64
    enum CodingKeys: String, CodingKey { case version; case chainID = "chain_id"; case currentCycle = "current_cycle" }
}

struct MainnetBalance: Decodable, Equatable, Sendable {
    let address: String
    let finalBalance: String
    let candidateBalance: String
    enum CodingKeys: String, CodingKey { case address; case finalBalance = "final_balance"; case candidateBalance = "candidate_balance" }
    var hasValidAmounts: Bool {
        (try? MASAmount(finalBalance)) != nil && (try? MASAmount(candidateBalance)) != nil
    }
}

protocol MainnetReading: Sendable {
    func status() async throws -> MainnetStatus
    func balance(for address: String) async throws -> MainnetBalance
}

struct MainnetRPC: MainnetReading {
    let environment = MassaEnvironment.mainnet
    private let transport: any RPCTransport
    init(transport: any RPCTransport = MainnetURLSessionTransport()) { self.transport = transport }
    private struct Request<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: String
        let method: String
        let params: Params
    }
    private struct Response<Result: Decodable>: Decodable {
        let jsonrpc: String
        let id: String
        let result: Result?
        let error: RPCError?
        struct RPCError: Decodable { let code: Int }
    }
    enum ReadMethod: String, CaseIterable { case status = "get_status", addresses = "get_addresses" }
    private func call<Params: Encodable, Result: Decodable>(_ method: ReadMethod, params: Params) async throws -> Result {
        let id = UUID().uuidString
        var request = URLRequest(url: environment.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(id: id, method: method.rawValue, params: params))
        let response: RPCTransportResponse
        do { response = try await readWithRetry(request) }
        catch is CancellationError { throw MainnetRPCError.cancelled }
        catch let error as URLError {
            switch error.code {
            case .timedOut: throw MainnetRPCError.timedOut
            case .cancelled: throw MainnetRPCError.cancelled
            default: throw MainnetRPCError.offline
            }
        }
        catch let error as MainnetRPCError { throw error }
        catch { throw MainnetRPCError.offline }
        if response.statusCode == 429 { throw MainnetRPCError.rateLimited }
        guard (200..<300).contains(response.statusCode) else { throw MainnetRPCError.http(response.statusCode) }
        guard response.data.count <= 1_048_576 else { throw MainnetRPCError.invalidResponse }
        guard let envelope = try? JSONDecoder().decode(Response<Result>.self, from: response.data),
              envelope.jsonrpc == "2.0", envelope.id == id,
              (envelope.result != nil) != (envelope.error != nil) else { throw MainnetRPCError.invalidResponse }
        if let error = envelope.error { throw MainnetRPCError.rpc(error.code) }
        guard let result = envelope.result else { throw MainnetRPCError.invalidResponse }
        return result
    }
    private func readWithRetry(_ request: URLRequest) async throws -> RPCTransportResponse {
        for attempt in 0...1 {
            do {
                let response = try await transport.send(request)
                if attempt == 0 && (response.statusCode == 429 || (500...599).contains(response.statusCode)) {
                    try await Task.sleep(for: .milliseconds(500)); continue
                }
                return response
            } catch let error as URLError where attempt == 0 && [.timedOut, .notConnectedToInternet, .networkConnectionLost].contains(error.code) {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw MainnetRPCError.offline
    }
    func status() async throws -> MainnetStatus {
        let result: MainnetStatus = try await call(.status, params: [String]())
        guard result.chainID == environment.chainID else { throw MainnetRPCError.wrongNetwork }
        return result
    }
    func balance(for address: String) async throws -> MainnetBalance {
        do { try MassaPublicAccount.validateUserAddress(address) }
        catch { throw MainnetRPCError.invalidAddress }
        // Check identity before sending the address. A healthy HTTP response alone is insufficient.
        _ = try await status()
        let results: [MainnetBalance] = try await call(.addresses, params: [[address]])
        guard results.count == 1, let balance = results.first,
              balance.address == address, balance.hasValidAmounts else { throw MainnetRPCError.invalidResponse }
        return balance
    }
}
