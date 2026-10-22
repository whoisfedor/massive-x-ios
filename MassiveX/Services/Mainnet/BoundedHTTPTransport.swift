import Foundation

enum HTTPTransportError: Error, Equatable { case bodyTooLarge, unsupportedEndpoint, invalidResponse }

/// Fixed application endpoints, with limits on decoded bytes delivered by URLSession.
enum HTTPBodyPolicy {
    static func limit(for url: URL?) throws -> Int {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { throw HTTPTransportError.unsupportedEndpoint }
        switch url.host {
        case "explorer-api.massa.net": return 2_097_152
        case "mainnet.massa.net", "api.coingecko.com", "api.frankfurter.dev": return 1_048_576
        default: throw HTTPTransportError.unsupportedEndpoint
        }
    }
}
struct HTTPBodyBuffer {
    let limit: Int
    private(set) var data = Data()
    mutating func append(_ bytes: Data) throws {
        guard bytes.count <= limit - data.count else { throw HTTPTransportError.bodyTooLarge }
        data.append(bytes)
    }
    mutating func clear() { data = Data() }
}
/// Immutable copied configuration; no mutable configuration is exposed across requests.
private final class HTTPConfiguration: @unchecked Sendable {
    let value: URLSessionConfiguration
    init(_ configuration: URLSessionConfiguration) { value = configuration.copy() as! URLSessionConfiguration }
}
struct MainnetURLSessionTransport: RPCTransport {
    private let configuration: HTTPConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.timeoutIntervalForRequest = 15; copy.timeoutIntervalForResource = 20
        copy.waitsForConnectivity = false; copy.urlCache = nil; copy.httpCookieStorage = nil; copy.httpShouldSetCookies = false
        self.configuration = HTTPConfiguration(copy)
    }
    func send(_ request: URLRequest) async throws -> RPCTransportResponse {
        let receiver = BoundedHTTPReceiver(limit: try HTTPBodyPolicy.limit(for: request.url))
        return try await receiver.run(request, configuration: configuration.value)
    }
}

/// Every mutable field is lock-protected. Completion/cancellation resumes exactly once, outside the lock.
private final class BoundedHTTPReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var body: HTTPBodyBuffer
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<RPCTransportResponse, any Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var finished = false
    init(limit: Int) { self.limit = limit; body = HTTPBodyBuffer(limit: limit) }
    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> RPCTransportResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task: URLSessionDataTask? = lock.withLock {
                    guard !finished else { return nil }
                    self.continuation = continuation
                    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    let task = session.dataTask(with: request)
                    self.session = session; self.task = task
                    return task
                }
                if let task { task.resume() } else { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
    private func finish(_ result: Result<RPCTransportResponse, any Error>) {
        let resources: (CheckedContinuation<RPCTransportResponse, any Error>?, URLSessionDataTask?, URLSession?)? = lock.withLock {
            guard !finished else { return nil }; finished = true
            let resources = (continuation, task, session)
            continuation = nil; task = nil; session = nil; body.clear()
            return resources
        }
        guard let resources else { return }
        resources.1?.cancel(); resources.2?.invalidateAndCancel()
        resources.0?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); finish(.failure(HTTPTransportError.invalidResponse)); return }
        // Expected length can be absent or describe compressed bytes; actual decoded bytes are always counted below.
        guard response.expectedContentLength <= Int64(limit) else { completionHandler(.cancel); finish(.failure(HTTPTransportError.bodyTooLarge)); return }
        let accept = lock.withLock { if finished { return false }; self.response = response; return true }
        completionHandler(accept ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock {
            guard !finished else { return false }
            do { try body.append(data); return false } catch { return true }
        }
        if overflow { finish(.failure(HTTPTransportError.bodyTooLarge)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)); return }
        let result: Result<RPCTransportResponse, any Error> = lock.withLock {
            guard let response else { return .failure(HTTPTransportError.invalidResponse) }
            return .success(RPCTransportResponse(data: body.data, statusCode: response.statusCode,
                                                contentType: response.value(forHTTPHeaderField: "Content-Type")))
        }
        finish(result)
    }
}
