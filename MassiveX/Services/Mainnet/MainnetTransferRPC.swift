import Foundation

/// Explicit source-reviewed versions, shared by live status and durable provider receipts.
/// Unknown versions remain unsupported; neither a prefix nor semantic-version range is sufficient.
enum MainnetProtocolCompatibility {
    static func supports(_ version: String) -> Bool {
        version == "MAIN.5.0" || version == "MAIN.5.1"
    }
}

/// Exact public Mainnet methods. Submission has no automatic retry.
struct MainnetTransferRPC: TransferNetworking {
    private let transport: any RPCTransport
    init(transport: any RPCTransport = MainnetURLSessionTransport()) { self.transport = transport }
    private func call<P: Encodable, R: Decodable>(_ method: String, params: P) async throws -> R {
        guard MassaEnvironment.mainnet.endpoint.absoluteString == TrustedMassaRPCResolution.endpoint else { throw SendFailure.response }
        let id = UUID().uuidString
        var request = URLRequest(url: MassaEnvironment.mainnet.endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TransferRequest(id: id, method: method, params: params))
        let response = try await transport.send(request)
        guard response.statusCode == 200, response.data.count <= 1_048_576 else { throw SendFailure.response }
        let decoded = try JSONDecoder().decode(TransferResponse<R>.self, from: response.data)
        guard decoded.id == id, decoded.jsonrpc == "2.0", decoded.error == nil, let result = decoded.result else { throw SendFailure.response }
        return result
    }
    private struct Status: Decodable {
        let chain_id: UInt64; let version: String; let last_slot: Slot; let minimal_fees: String; let current_time: UInt64; let config: Config
        let execution_stats: ExecutionStats?
        struct ExecutionStats: Decodable { let final_cursor: Slot }
        struct Slot: Decodable { let period: UInt64 }
        struct Config: Decodable { let operation_validity_periods: UInt64 }
    }
    private func status() async throws -> Status {
        let result: Status = try await call("get_status", params: [String]())
        guard result.chain_id == MassaEnvironment.mainnet.chainID, MainnetProtocolCompatibility.supports(result.version),
              abs(Date().timeIntervalSince1970 - Double(result.current_time) / 1000) <= 20 else { throw SendFailure.stale }
        return result
    }
    func snapshot(source: String, recipient: String) async throws -> SendSnapshot {
        try MassaPublicAccount.validateUserAddress(source); try MassaPublicAccount.validateUserAddress(recipient)
        // Age the whole read bundle from its oldest request, not its completion.
        let fetched = Date()
        let status = try await status()
        let balances: [MainnetBalance] = try await call("get_addresses", params: [[source, recipient]])
        guard balances.count == 2, balances[0].address == source, balances[1].address == recipient else { throw SendFailure.response }
        return try SendSnapshot(fetched: fetched, chainID: status.chain_id, period: status.last_slot.period,
            validity: status.config.operation_validity_periods, fee: MASAmount(status.minimal_fees),
            finalBalance: MASAmount(balances[0].finalBalance), candidateBalance: MASAmount(balances[0].candidateBalance),
            recipientFinal: MASAmount(balances[1].finalBalance), recipientCandidate: MASAmount(balances[1].candidateBalance))
    }
    struct Input: Codable, Sendable {
        let serialized_content: [UInt8]
        let creator_public_key: String
        let signature: String
    }
    static func input(_ draft: ReviewedTransfer, signature: String) throws -> Input {
        try draft.validate()
        guard draft.recipientCredit != nil else { throw SendFailure.changed }
        let publicAccount = try MassaPublicAccount(rawPublicKey: MassaCodec.decode(draft.wallet.publicKey, prefix: "P"))
        guard try publicAccount.verify(message: MassaOperationEncoding.canonical(content: draft.content, publicKey: draft.wallet.publicKey), signature: signature) else { throw SendFailure.keyUnavailable }
        return Input(serialized_content: Array(draft.content), creator_public_key: draft.wallet.publicKey, signature: signature)
    }
    func submit(_ draft: ReviewedTransfer, signature: String) async throws -> String {
        let input = try Self.input(draft, signature: signature)
        let result: [String] = try await call("send_operations", params: [[input]])
        guard result == [draft.operationID] else { throw SendFailure.response }
        return result[0]
    }
    func lookup(operationID: String) async throws -> SubmissionState {
        _ = try MassaCodec.decode(operationID, prefix: "O")
        _ = try await status()
        return try await operationState(operationID)
    }
    func reconciliation(for draft: ReviewedTransfer) async throws -> ReconciliationAssessment {
        try draft.validate()
        let started = Date(), status = try await status()
        // Same-provider consistency reads, NOT independent corroboration.
        var observations: [NodeObservation] = [], reports: [TrustedMassaRPCResolution.Report] = []
        for _ in 0..<2 {
            let operation = try await operation(draft.operationID)
            let state = try operation?.state() ?? .outcomeUnknown
            let observation = NodeObservation(operationID: draft.operationID, chainID: status.chain_id,
                endpoint: TrustedMassaRPCResolution.endpoint, operatorID: "massa-labs",
                nodeVersion: status.version, reportedState: state, observedAt: Date(),
                reportedFinalPeriod: status.execution_stats?.final_cursor.period)
            observations.append(observation)
            if state == .finalized || state == .failed, let operation {
                try operation.validateCanonical(for: draft)
                reports.append(.init(observation: observation, sourcePublicKey: draft.wallet.publicKey,
                                     sourceAddress: draft.wallet.address, content: draft.content))
            }
        }
        let checkedAt = Date()
        var assessment = ReconciliationAssessment.combine(observations[0].reportedState, observations[1].reportedState,
            finalPeriod: status.execution_stats?.final_cursor.period, expiry: draft.expiry,
            now: checkedAt, operationID: draft.operationID, observations: observations)
        if reports.count == 2, reports[0].observation.reportedState == reports[1].observation.reportedState {
            _ = try await self.status() // Recheck chain, supported version and freshness before accepting the bundle.
            let resolution = TrustedMassaRPCResolution(policy: TrustedMassaRPCResolution.policyID,
                acceptedAt: Date(), reports: reports)
            guard resolution.acceptedAt.timeIntervalSince(started) <= 20 else { throw SendFailure.stale }
            try resolution.validate(for: draft, now: Date())
            assessment = ReconciliationAssessment(state: reports[0].observation.reportedState, reason: .trustedMassaLabs,
                checkedAt: resolution.acceptedAt, reportedFinalPeriod: status.execution_stats?.final_cursor.period,
                reportedState: reports[0].observation.reportedState, observations: observations,
                terminalClaims: [reports[0].observation.reportedState], providerResolution: resolution)
        }
        return assessment
    }
    private struct Operation: Decodable {
        let id: String
        let in_pool: Bool
        let is_operation_final: Bool?
        let op_exec_status: Bool?
        let operation: SignedOperation?
        struct SignedOperation: Decodable {
            let id: String
            let content_creator_pub_key: String
            let content_creator_address: String
            let signature: String
            let content: Content
        }
        struct Content: Decodable {
            let fee: String
            let expire_period: UInt64
            let op: [String: Transaction]
        }
        struct Transaction: Decodable { let recipient_address: String; let amount: String }
        func state() throws -> SubmissionState {
            if is_operation_final == true {
                guard !in_pool, let success = op_exec_status else { throw SendFailure.response }
                return success ? .finalized : .failed
            }
            return in_pool || op_exec_status != nil ? .pending : .outcomeUnknown
        }
        func validateCanonical(for draft: ReviewedTransfer) throws {
            guard let operation, operation.id == draft.operationID, id == draft.operationID,
                  operation.content_creator_pub_key == draft.wallet.publicKey,
                  operation.content_creator_address == draft.wallet.address,
                  Set(operation.content.op.keys) == ["Transaction"],
                  let transfer = operation.content.op["Transaction"], transfer.recipient_address == draft.recipient,
                  try MASAmount(transfer.amount) == draft.amount, try MASAmount(operation.content.fee) == draft.fee,
                  operation.content.expire_period == draft.expiry else { throw SendFailure.response }
            let content = try MassaOperationEncoding.serialized(fee: MASAmount(operation.content.fee),
                amount: MASAmount(transfer.amount), expirePeriod: operation.content.expire_period, recipient: transfer.recipient_address)
            let publicAccount = try MassaPublicAccount(rawPublicKey: MassaCodec.decode(operation.content_creator_pub_key, prefix: "P"))
            guard content == draft.content, publicAccount.address == draft.wallet.address,
                  try MassaOperationEncoding.operationID(content: content, publicKey: operation.content_creator_pub_key) == draft.operationID,
                  try publicAccount.verify(message: MassaOperationEncoding.canonical(content: content, publicKey: operation.content_creator_pub_key),
                                           signature: operation.signature) else { throw SendFailure.response }
        }
    }
    private func operation(_ operationID: String) async throws -> Operation? {
        let operations: [Operation] = try await call("get_operations", params: [[operationID]])
        guard operations.count <= 1 else { throw SendFailure.response }
        guard let operation = operations.first else { return nil }
        guard operation.id == operationID else { throw SendFailure.response }
        return operation
    }
    private func operationState(_ operationID: String) async throws -> SubmissionState {
        try await operation(operationID)?.state() ?? .outcomeUnknown
    }

}
struct TransferRequest<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: String
    let method: String
    let params: P
}
private struct TransferResponse<R: Decodable>: Decodable {
    let jsonrpc: String; let id: String; let result: R?; let error: RPCError?
    struct RPCError: Decodable { let code: Int }
}
