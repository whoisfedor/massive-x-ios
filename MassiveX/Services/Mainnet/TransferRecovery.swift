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
