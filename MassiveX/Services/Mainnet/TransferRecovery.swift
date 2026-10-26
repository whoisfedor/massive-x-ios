import Foundation

/// Portable PUBLIC intent records only. Not signed, not a clean-history certificate or a key backup.
struct PublicOperationFile: Codable, Equatable, Sendable {
    static let maximumBytes = 33_554_432
    let format: String
    let version: Int
    let chainID: UInt64
    let operations: [ReviewedTransfer]
    init(operations: [ReviewedTransfer]) {
        format = "massive-x-public-operations"; version = 1
        chainID = MassaEnvironment.mainnet.chainID; self.operations = operations
    }
    func validate(for wallet: SendWallet) throws {
        guard format == "massive-x-public-operations", version == 1, chainID == MassaEnvironment.mainnet.chainID,
              !operations.isEmpty, operations.count <= TransferJournalPolicy.maximumRecords,
              Set(operations.map(\.operationID)).count == operations.count,
              operations.allSatisfy({ $0.wallet.sourceIdentity == wallet.sourceIdentity }) else { throw SendFailure.response }
        for operation in operations { try operation.validate() }
    }
    static func decode(_ data: Data, for wallet: SendWallet) throws -> Self {
        guard data.count <= maximumBytes else { throw SendFailure.response }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(for: wallet); return value
    }
    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw SendFailure.response }; return data
    }
    static func read(_ url: URL, for wallet: SendWallet) throws -> Self {
        guard let input = InputStream(url: url) else { throw SendFailure.response }
        input.open(); defer { input.close() }
        var body = HTTPBodyBuffer(limit: maximumBytes), chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = input.read(&chunk, maxLength: chunk.count)
            guard count >= 0 else { throw SendFailure.response }
            if count == 0 { break }
            try body.append(Data(chunk.prefix(count)))
        }
        return try decode(body.data, for: wallet)
    }
}
extension SendCoordinator {
    func publicOperationFile(for wallet: SendWallet) throws -> PublicOperationFile {
        guard journalIssue == nil else { throw SendFailure.journal }
        let file = PublicOperationFile(operations: pending.filter { $0.draft.wallet.sourceIdentity == wallet.sourceIdentity }.map(\.draft))
        try file.validate(for: wallet); return file
    }
}

/// Fixed official Explorer evidence is NOT RPC finality or independent consensus proof.
/// Decode/validation compatibility for receipts written by earlier app versions only.
struct HistoricalEvidence: Codable, Equatable, Sendable {
    static let endpoint = "https://explorer-api.massa.net"
    // The official Explorer API exposes unsigned integer nano-MAS, unlike JSON-RPC MAS strings.
    static func amount(_ raw: String) throws -> MASAmount {
        guard let nano = UInt64(raw), String(nano) == raw else { throw SendFailure.historicalEvidence }
        return MASAmount(nano: nano)
    }
    struct Operation: Codable, Equatable, Sendable {
        let id: String
        let in_blocks: [String]
        let thread: UInt8
        let in_pool: Bool
        let is_operation_final: Bool
        let op_exec_status: Bool
        let timestamp: String
        let operation: Signed
        struct Signed: Codable, Equatable, Sendable {
            let id: String
            let content_creator_pub_key: String
            let content_creator_address: String
            let signature: String
            let content: Content
        }
        struct Content: Codable, Equatable, Sendable {
            let fee: String
            let expire_period: UInt64
            let op: [String: Transaction?]
        }
        struct Transaction: Codable, Equatable, Sendable { let amount: String; let recipient_address: String }
        func validate(for draft: ReviewedTransfer) throws {
            try draft.validate()
            let signed = operation, content = signed.content
            // Pool membership is auxiliary metadata, not candidate/final execution evidence.
            // MAIN.5.1 public.rs obtains it independently; the index may retain its old value.
            guard id == draft.operationID, signed.id == id, is_operation_final, op_exec_status,
                  thread < 32, !in_blocks.isEmpty, in_blocks.count <= 8, Set(in_blocks).count == in_blocks.count,
                  signed.content_creator_pub_key == draft.wallet.publicKey, signed.content_creator_address == draft.wallet.address,
                  Set(content.op.keys).isSubset(of: ["Transaction", "RollBuy", "RollSell", "ExecuteSC", "CallSC"]),
                  let item = content.op["Transaction"], let transaction = item,
                  content.op.allSatisfy({ $0.key == "Transaction" || $0.value == nil }),
                  transaction.recipient_address == draft.recipient, try HistoricalEvidence.amount(transaction.amount) == draft.amount,
                  try HistoricalEvidence.amount(content.fee) == draft.fee, content.expire_period == draft.expiry,
                  let millis = UInt64(timestamp), millis > 0, String(millis) == timestamp,
                  millis <= UInt64(Date().addingTimeInterval(300).timeIntervalSince1970 * 1000) else { throw SendFailure.historicalEvidence }
            for block in in_blocks { _ = try MassaCodec.decode(block, prefix: "B") }
            let bytes = try MassaOperationEncoding.serialized(fee: HistoricalEvidence.amount(content.fee), amount: HistoricalEvidence.amount(transaction.amount),
                expirePeriod: content.expire_period, recipient: transaction.recipient_address)
            let account = try MassaPublicAccount(rawPublicKey: MassaCodec.decode(signed.content_creator_pub_key, prefix: "P"))
            guard bytes == draft.content, account.address == draft.wallet.address,
                  try MassaOperationEncoding.operationID(content: bytes, publicKey: account.publicKey) == id,
                  try account.verify(message: MassaOperationEncoding.canonical(content: bytes, publicKey: account.publicKey), signature: signed.signature)
                else { throw SendFailure.historicalEvidence }
        }
    }
    struct BlockEnvelope: Codable, Equatable, Sendable { let block: Block }
    struct Block: Codable, Equatable, Sendable {
        let hash: String
        let is_final: Bool
        let period: UInt64
        let thread: UInt8
        let block_time: String
        let latest_ops: [Row]
        struct Row: Codable, Equatable, Sendable {
            let hash: String
            let status: String
            let type: String
            let from: String
            let to: String
            let value: String
            let transaction_fee: String
            let op_exec_status: Bool
        }
        func retainingOnly(_ operationID: String) -> Self {
            Self(hash: hash, is_final: is_final, period: period, thread: thread, block_time: block_time,
                 latest_ops: latest_ops.filter { $0.hash == operationID })
        }
        func validate(for draft: ReviewedTransfer, operation: Operation) throws {
            _ = try MassaCodec.decode(hash, prefix: "B")
            let matches = latest_ops.filter { $0.hash == draft.operationID }
            guard is_final, operation.in_blocks.contains(hash), thread == operation.thread, period <= draft.expiry,
                  block_time == operation.timestamp, matches.count == 1, let row = matches.first,
                  row.status == "Final", row.type == "Transaction", row.op_exec_status,
                  row.from == draft.wallet.address, row.to == draft.recipient,
                  try HistoricalEvidence.amount(row.value) == draft.amount, try HistoricalEvidence.amount(row.transaction_fee) == draft.fee else { throw SendFailure.historicalEvidence }
        }
    }
    struct Report: Codable, Equatable, Sendable {
        let endpoint: String
        let network: String
        let observedAt: Date
        let operation: Operation
        let block: Block
    }
    let chainID: UInt64
    let nodeVersion: String
    let reports: [Report]
    func validate(for draft: ReviewedTransfer) throws {
        guard chainID == MassaEnvironment.mainnet.chainID, MainnetProtocolCompatibility.supports(nodeVersion), reports.count == 2,
              reports[0].operation == reports[1].operation, reports[0].block == reports[1].block,
              reports[1].observedAt >= reports[0].observedAt else { throw SendFailure.historicalEvidence }
        for report in reports {
            guard report.endpoint == Self.endpoint, report.network == "mainnet" else { throw SendFailure.historicalEvidence }
            try report.operation.validate(for: draft); try report.block.validate(for: draft, operation: report.operation)
        }
    }
    func sameStatement(as other: Self) -> Bool {
        chainID == other.chainID && nodeVersion == other.nodeVersion && reports.first?.operation == other.reports.first?.operation && reports.first?.block == other.reports.first?.block
    }
}
struct OwnerHistoricalResolution: Codable, Equatable, Sendable {
    static let policyID = "owner-reviewed-official-explorer-success-v1"
    let policy: String
    let authorizationMethod: String
    let authorizedAt: Date
    let acceptedAt: Date
    let evidence: HistoricalEvidence
    func validate(for draft: ReviewedTransfer) throws {
        guard policy == Self.policyID, authorizationMethod == "deviceOwnerAuthentication",
              (0...30).contains(acceptedAt.timeIntervalSince(authorizedAt)) else { throw SendFailure.historicalEvidence }
        try evidence.validate(for: draft)
        for report in evidence.reports {
            guard report.observedAt >= authorizedAt, (0...30).contains(acceptedAt.timeIntervalSince(report.observedAt)) else { throw SendFailure.historicalEvidence }
        }
    }
}
