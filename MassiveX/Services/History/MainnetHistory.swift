import Foundation
import Observation

struct HistoryCursor: Equatable, Sendable { let created: String?; let received: String? }
enum HistoryDirection: String, Sendable { case created, received }

/// Explorer event identity is distinct from its optional parent chain operation ID.
struct HistoryIdentity {
    let operationID: String?
    let transferIndex: UInt64?
    init(_ raw: String) throws {
        guard raw.utf8.count <= 256, raw.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else { throw HistoryError.invalidResponse }
        if raw.hasPrefix("ASC_"), raw.contains("_I"), raw.contains("_T") {
            // Official frontend treats these as autonomous indexer records, with no operation link.
            operationID = nil; transferIndex = nil; return
        }
        let parts = raw.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { throw HistoryError.invalidResponse }
        let parent = String(parts[0]); _ = try MassaCodec.decode(parent, prefix: "O")
        operationID = parent
        if parts.count == 2 {
            guard let index = UInt64(parts[1]), String(index) == parts[1] else { throw HistoryError.invalidResponse }
            transferIndex = index
        } else { transferIndex = nil }
    }
}
struct MainnetOperation: Identifiable, Equatable, Sendable {
    enum Direction { case incoming, outgoing, own, contract, other }
    let id: String
    let type: String
    let sender: String
    let recipient: String?
    let amount: MASAmount?
    let fee: MASAmount?
    let date: Date?
    let status: String
    let executionSucceeded: Bool?
    var operationID: String? { try? HistoryIdentity(id).operationID }
    var transferIndex: UInt64? { try? HistoryIdentity(id).transferIndex }
    var explorerURL: URL? { operationID.flatMap { URL(string: "https://explorer.massa.net/mainnet/operation/" + $0) } }
    func shortCounterparty(for address: String) -> String? {
        guard let other = sender == address ? recipient : sender else { return nil }
        return String(other.prefix(6)) + "…" + other.suffix(5)
    }
    func direction(for address: String) -> Direction {
        if type == "CallSC" || type == "ExecuteSC" { return .contract }
        guard type == "Transaction" else { return .other }
        if sender == address && recipient == address { return .own }
        return sender == address ? .outgoing : .incoming
    }
    var statusLabel: String {
        if status == "Final" {
            if let executionSucceeded { return L(executionSucceeded ? "Finalized" : "Finalized · Failed") }
            return L("Finalized · Execution unknown")
        }
        return L("Not final")
    }
    func title(for address: String) -> String {
        switch direction(for: address) {
        case .incoming: L("Received")
        case .outgoing: L("Sent")
        case .own: L("Self transfer")
        case .contract: L("Contract interaction")
        case .other: L("Other operation")
        }
    }
}

enum HistoryError: Error, Equatable, Sendable {
    case unavailable, invalidResponse, offline, timedOut, tls, rateLimited, http(Int), redirected, contentType, emptyBody, oversized, invalidAddress, cancelled
    var code: String {
        switch self {
        case .unavailable: "SERVICE"
        case .invalidResponse: "SCHEMA"
        case .offline: "NETWORK"
        case .timedOut: "TIMEOUT"
        case .tls: "TLS"
        case .rateLimited: "HTTP_429"
        case .http(let status): "HTTP_\(status)"
        case .redirected: "REDIRECT"
        case .contentType: "CONTENT_TYPE"
        case .emptyBody: "EMPTY_BODY"
        case .oversized: "RESPONSE_SIZE"
        case .invalidAddress: "ADDRESS"
        case .cancelled: "CANCELLED"
        }
    }
    var message: String {
        switch self {
        case .offline: L("History connection unavailable. Check your connection and retry.")
        case .timedOut: L("History request timed out. Retry when connected.")
        case .tls: L("A secure history connection could not be established.")
        case .rateLimited: L("History requests are rate limited. Wait before retrying.")
        case .invalidResponse, .contentType, .emptyBody, .oversized: L("The history service returned an unsupported response.")
        case .invalidAddress: L("The selected address is not supported for history.")
        case .cancelled: L("History request cancelled.")
        default: L("History service unavailable. Retry later.")
        }
    }
    static func classify(_ error: any Error) -> HistoryError {
        if (error as? HTTPTransportError) == .bodyTooLarge { return .oversized }
        if let error = error as? HistoryError { return error }
        if error is CancellationError { return .cancelled }
        guard let error = error as? URLError else { return .invalidResponse }
        switch error.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: return .tls
        default: return .offline
        }
    }
}
struct HistoryDiagnostic: Equatable, Sendable {
    let direction: HistoryDirection
    let httpStatus: Int?
    let contentType: String?
    let responseBytes: Int?
    let error: HistoryError?
    // Only these fields may cross a logging/report boundary. The state cache itself is address-keyed.
    var redactedFields: [String: String] {
        ["direction": direction.rawValue, "status": httpStatus.map(String.init) ?? "none",
         "contentType": contentType ?? "none", "bytes": responseBytes.map(String.init) ?? "none",
         "error": error?.code ?? "none"]
    }
    // No address, full URL, opaque cursor, body or server error description is retained.
}
enum HistoryIssue: Equatable, Sendable {
    case directionFailed(HistoryDirection, HistoryError), invalidRows(Int), impreciseAmounts(Int)
}
struct HistoryPage: Sendable {
    let operations: [MainnetOperation]
    let cursor: HistoryCursor?
    let issues: [HistoryIssue]
    let diagnostics: [HistoryDiagnostic]
    init(operations: [MainnetOperation], cursor: HistoryCursor?, issues: [HistoryIssue] = [], diagnostics: [HistoryDiagnostic] = []) {
        self.operations = operations; self.cursor = cursor; self.issues = issues; self.diagnostics = diagnostics
    }
}
protocol MainnetHistoryReading: Sendable { func page(address: String, cursor: HistoryCursor?) async throws -> HistoryPage }
private struct HistoryRequestFailure: Error { let diagnostic: HistoryDiagnostic }

/// Typed adapter for the current official explorer contract; never scrapes HTML or rounds nano-MAS.
struct MainnetHistoryClient: MainnetHistoryReading {
    private let transport: any RPCTransport
    init(transport: any RPCTransport = MainnetURLSessionTransport()) { self.transport = transport }
    func page(address: String, cursor: HistoryCursor?) async throws -> HistoryPage {
        guard (try? MassaPublicAccount.validateAddress(address)) != nil else { throw HistoryError.invalidAddress }
        // Independent reads preserve a valid direction when the other direction is unavailable.
        async let created = read(address: address, direction: .created, cursor: cursor?.created, enabled: cursor == nil || cursor?.created != nil)
        async let received = read(address: address, direction: .received, cursor: cursor?.received, enabled: cursor == nil || cursor?.received != nil)
        let results = await [created, received]
        try Task.checkCancellation()
        var operations: [MainnetOperation] = [], issues: [HistoryIssue] = [], diagnostics: [HistoryDiagnostic] = []
        var nextCreated: String?, nextReceived: String?, successful = 0, failure: HistoryError?
        for (index, result) in results.enumerated() {
            let direction: HistoryDirection = index == 0 ? .created : .received
            switch result {
            case .success(let page):
                guard let page else { continue }; successful += 1
                operations += page.operations; issues += page.issues; diagnostics += page.diagnostics
                if direction == .created { nextCreated = page.cursor?.created } else { nextReceived = page.cursor?.received }
            case .failure(let error):
                let diagnostic = (error as? HistoryRequestFailure)?.diagnostic
                let category = diagnostic?.error ?? HistoryError.classify(error)
                failure = failure ?? category; issues.append(.directionFailed(direction, category))
                diagnostics.append(diagnostic ?? HistoryDiagnostic(direction: direction, httpStatus: nil, contentType: nil, responseBytes: nil, error: category))
                // Empty cursor denotes a failed first page, not an exhausted direction.
                if direction == .created { nextCreated = cursor?.created ?? "" } else { nextReceived = cursor?.received ?? "" }
            }
        }
        guard successful > 0 else { throw HistoryRequestFailure(diagnostic: diagnostics.first ?? HistoryDiagnostic(direction: .created, httpStatus: nil, contentType: nil, responseBytes: nil, error: failure ?? .invalidResponse)) }
        let next = nextCreated == nil && nextReceived == nil ? nil : HistoryCursor(created: nextCreated, received: nextReceived)
        return HistoryPage(operations: operations, cursor: next, issues: issues, diagnostics: diagnostics)
    }
    private func read(address: String, direction: HistoryDirection, cursor: String?, enabled: Bool) async -> Result<HistoryPage?, any Error> {
        guard enabled else { return .success(nil) }
        var diagnostic = HistoryDiagnostic(direction: direction, httpStatus: nil, contentType: nil, responseBytes: nil, error: nil)
        do {
            var url = URLComponents(string: "https://explorer-api.massa.net/address/\(address)/operations")!
            var query = [URLQueryItem(name: direction == .created ? "from" : "to", value: "true")]
            if let cursor, !cursor.isEmpty {
                guard cursor.utf8.count <= 8192 else { throw HistoryError.invalidResponse }
                query.append(URLQueryItem(name: direction == .created ? "cursorCreated" : "cursorReceived", value: cursor))
            }
            url.queryItems = query
            url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "GET"; request.setValue("mainnet", forHTTPHeaderField: "x-network")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let response = try await readWithRetry(request)
            diagnostic = HistoryDiagnostic(direction: direction, httpStatus: response.statusCode, contentType: response.contentType.map { value in
                let media = value.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "other"
                return ["application/json", "text/html", "text/plain", "application/problem+json"].contains(media) ? media : "other"
            }, responseBytes: response.data.count, error: nil)
            if response.statusCode == 429 { throw HistoryError.rateLimited }
            if (300..<400).contains(response.statusCode) { throw HistoryError.redirected }
            guard response.statusCode == 200 else { throw HistoryError.http(response.statusCode) }
            guard response.data.count <= 2_097_152 else { throw HistoryError.oversized }
            guard !response.data.isEmpty else { throw HistoryError.emptyBody }
            let media = response.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
            guard media == "application/json" else { throw HistoryError.contentType }
            let page = try Self.decode(response.data, address: address, direction: direction)
            return .success(HistoryPage(operations: page.operations, cursor: page.cursor, issues: page.issues, diagnostics: [diagnostic]))
        } catch {
            let failure = HistoryDiagnostic(direction: direction, httpStatus: diagnostic.httpStatus, contentType: diagnostic.contentType, responseBytes: diagnostic.responseBytes, error: HistoryError.classify(error))
            return .failure(HistoryRequestFailure(diagnostic: failure))
        }
    }
    private func readWithRetry(_ request: URLRequest) async throws -> RPCTransportResponse {
        for attempt in 0...1 {
            try Task.checkCancellation()
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
        throw HistoryError.offline
    }
    private static func nano(_ string: String?) -> (amount: MASAmount?, inexact: Bool) {
        guard let string, string != "-" else { return (nil, false) }
        // Exact zero-only fractional suffixes are accepted. Sub-nano values are never rounded.
        guard string.utf8.count <= 45, string.range(of: #"^[0-9]{1,20}(?:\.0{1,20})?\z"#, options: .regularExpression) != nil,
              let whole = string.split(separator: ".").first, let value = UInt64(whole) else { return (nil, true) }
        return (MASAmount(nano: value), false)
    }

    static func decode(_ data: Data, address: String, direction: HistoryDirection? = nil) throws -> HistoryPage {
        struct Row: Decodable {
            let hash: String; let type: String; let from: String; let to: String?
            let value: String?; let transaction_fee: String?; let block_time: String?
            let status: String; let op_exec_status: Bool?
        }
        struct Candidate: Decodable {
            let row: Row?
            init(from decoder: any Decoder) throws { row = try? Row(from: decoder) }
        }
        struct Body: Decodable {
            let operationsNodes: [Candidate]?
            let operationsCreated: [Candidate]?
            let operationsReceived: [Candidate]?
            let nextCursorCreated: String?; let nextCursorReceived: String?
        }
        let body: Body
        do { body = try JSONDecoder().decode(Body.self, from: data) } catch { throw HistoryError.invalidResponse }
        guard (direction == .created ? body.operationsCreated != nil : direction == .received ? body.operationsReceived != nil : body.operationsCreated != nil && body.operationsReceived != nil) else { throw HistoryError.invalidResponse }
        var rows = body.operationsNodes ?? []
        if direction != .received { rows += body.operationsCreated ?? [] }
        if direction != .created { rows += body.operationsReceived ?? [] }
        guard rows.count <= 2000 else { throw HistoryError.invalidResponse }
        var operations: [MainnetOperation] = [], invalid = 0, imprecise = 0
        for candidate in rows {
            guard let row = candidate.row else { invalid += 1; continue }
            do {
                _ = try HistoryIdentity(row.hash)
                try MassaPublicAccount.validateAddress(row.from)
                if let to = row.to, to != "-" { try MassaPublicAccount.validateAddress(to) }
                guard row.from == address || row.to == address, !row.type.isEmpty else { throw HistoryError.invalidResponse }
                let amountResult = Self.nano(row.type == "Transaction" ? row.value : nil)
                let feeResult = Self.nano(row.transaction_fee)
                let amount = amountResult.amount, fee = feeResult.amount
                imprecise += (amountResult.inexact ? 1 : 0) + (feeResult.inexact ? 1 : 0)
                var date: Date?
                if let time = row.block_time, !time.isEmpty, time != "0" {
                    guard time.utf8.allSatisfy({ (48...57).contains($0) }), let ms = UInt64(time), ms < 10_000_000_000_000 else { throw HistoryError.invalidResponse }
                    date = Date(timeIntervalSince1970: Double(ms) / 1000)
                }
                operations.append(MainnetOperation(id: row.hash, type: row.type, sender: row.from, recipient: row.to == "-" ? nil : row.to,
                    amount: amount, fee: fee, date: date, status: row.status, executionSucceeded: row.op_exec_status))
            } catch { invalid += 1 }
        }
        guard rows.isEmpty || !operations.isEmpty else { throw HistoryError.invalidResponse }
        func checked(_ value: String?) throws -> String? {
            guard let value, !value.isEmpty else { return nil }
            guard value.utf8.count <= 8192 else { throw HistoryError.invalidResponse }
            return value
        }
        let created = try checked(body.nextCursorCreated), received = try checked(body.nextCursorReceived)
        var issues: [HistoryIssue] = []
        if invalid > 0 { issues.append(.invalidRows(invalid)) }
        if imprecise > 0 { issues.append(.impreciseAmounts(imprecise)) }
        return HistoryPage(operations: operations, cursor: created == nil && received == nil ? nil : HistoryCursor(created: created, received: received), issues: issues)
    }
}

enum HistoryLoadState: Equatable {
    case idle, loading, empty, loaded, partial, failed(HistoryError)
}
@MainActor @Observable final class MainnetHistory {
    static let shared = MainnetHistory()
    private(set) var items: [String: [MainnetOperation]] = [:]
    private(set) var updated: [String: Date] = [:]
    private(set) var failures: [String: HistoryError] = [:]
    private(set) var issues: [String: [HistoryIssue]] = [:]
    private(set) var diagnostics: [String: [HistoryDiagnostic]] = [:]
    var errors: Set<String> { Set(failures.keys) }
    private(set) var loading: Set<String> = []
    private(set) var cursors: [String: HistoryCursor] = [:]
    private var attempted: [String: Date] = [:]
    private var generations: [String: Int] = [:]
    @ObservationIgnored private var requests: [String: Task<HistoryPage, any Error>] = [:]
    private var activeAddress: String?
    private let client: any MainnetHistoryReading
    init(client: any MainnetHistoryReading = MainnetHistoryClient()) { self.client = client }
    func state(_ address: String) -> HistoryLoadState {
        if loading.contains(address) { return .loading }
        if let failure = failures[address] { return .failed(failure) }
        if !(issues[address] ?? []).isEmpty { return .partial }
        if updated[address] == nil { return .idle }
        return (items[address] ?? []).isEmpty ? .empty : .loaded
    }
    func presentationState(_ address: String, mode: HistoryMode) -> HistoryLoadState {
        let value = state(address)
        if value == .loaded && filtered(address, mode: mode).isEmpty { return .empty }
        return value
    }
    func activate(_ address: String?) {
        guard activeAddress != address else { return }; activeAddress = address
        for (other, task) in requests where other != address {
            task.cancel(); generations[other, default: 0] += 1
            loading.remove(other); requests[other] = nil; attempted[other] = nil
        }
    }
    func stale(_ address: String, now: Date = Date()) -> Bool {
        failures[address] != nil || !(issues[address] ?? []).isEmpty || updated[address].map { now.timeIntervalSince($0) > 60 } ?? true
    }
    func filtered(_ address: String, mode: HistoryMode) -> [MainnetOperation] { (items[address] ?? []).filter { mode.includes($0, for: address) } }
    func preview(_ address: String, mode: HistoryMode = .all) -> [MainnetOperation] { Array(filtered(address, mode: mode).prefix(3)) }
    func refresh(_ address: String, more: Bool = false, force: Bool = false, now: Date = Date()) async {
        guard !loading.contains(address) else { return }
        if let attempt = attempted[address], now.timeIntervalSince(attempt) < (force || more ? 2 : 30) { return }
        if more && cursors[address] == nil { return }
        let cursor = more ? cursors[address] : nil, token = generations[address, default: 0]
        attempted[address] = now; loading.insert(address)
        let client = self.client
        let request = Task { try await client.page(address: address, cursor: cursor) }; requests[address] = request
        defer { if token == generations[address, default: 0] { loading.remove(address); requests[address] = nil } }
        do {
            let page = try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
            guard token == generations[address, default: 0], !Task.isCancelled else { return }
            let lostDirection = page.issues.contains { if case .directionFailed = $0 { true } else { false } }
            var unique = Dictionary((more || lostDirection ? items[address] ?? [] : []).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for operation in page.operations { unique[operation.id] = operation }
            items[address] = unique.values.sorted {
                let a = $0.date ?? .distantFuture, b = $1.date ?? .distantFuture
                return a == b ? $0.id < $1.id : a > b
            }
            cursors[address] = page.cursor == cursor && more && !lostDirection ? nil : page.cursor
            let retainedIssues = more ? (issues[address] ?? []).filter { if case .directionFailed = $0 { false } else { true } } : []
            issues[address] = retainedIssues + page.issues; diagnostics[address] = page.diagnostics
            updated[address] = now; failures[address] = nil
        } catch {
            guard token == generations[address, default: 0], !Task.isCancelled else { return }
            if let failure = error as? HistoryRequestFailure { diagnostics[address] = [failure.diagnostic]; failures[address] = failure.diagnostic.error ?? .invalidResponse }
            else { failures[address] = HistoryError.classify(error) }
        }
    }
    func clear() {
        for task in requests.values { task.cancel() }
        for address in requests.keys { generations[address, default: 0] += 1 }
        requests = [:]; activeAddress = nil; items = [:]; updated = [:]; failures = [:]; issues = [:]; diagnostics = [:]; loading = []; cursors = [:]; attempted = [:]
    }
}

/// Uses verified explorer types and the existing validated internal/autonomous event identities.
enum HistoryMode: String, CaseIterable, Identifiable {
    case all, sent, received, smartContracts
    var id: String { rawValue }
    var title: String { L(titleKey) }
    var titleKey: String { switch self { case .all: "All"; case .sent: "Sent"; case .received: "Received"; case .smartContracts: "ASC" } }
    var accessibilityKey: String { self == .smartContracts ? "Smart contracts" : titleKey }
    func includes(_ operation: MainnetOperation, for address: String) -> Bool {
        let internalTransfer = operation.transferIndex != nil || operation.id.hasPrefix("ASC_")
        let contract = operation.type == "CallSC" || operation.type == "ExecuteSC" || (operation.type == "Transaction" && internalTransfer)
        if self == .smartContracts { return contract }
        guard operation.type == "Transaction", !internalTransfer,
              operation.sender == address || operation.recipient == address else { return false }
        switch self {
        case .all: return true
        case .sent: return operation.sender == address
        case .received: return operation.recipient == address
        case .smartContracts: return false
        }
    }
    static func migrated(_ raw: String?) -> Self {
        if raw == "transactions" || raw == "both" { return .all }
        return raw.flatMap(Self.init(rawValue:)) ?? .all
    }
}
@MainActor @Observable final class HistoryPreferences {
    static let shared = HistoryPreferences()
    private let defaults: UserDefaults
    var mode: HistoryMode { didSet { defaults.set(mode.rawValue, forKey: "history.mode") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = HistoryMode.migrated(defaults.string(forKey: "history.mode"))
        defaults.set(mode.rawValue, forKey: "history.mode")
    }
}
