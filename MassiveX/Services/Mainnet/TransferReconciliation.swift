import Foundation

/// Client-stamped RPC provenance, never an independent canonical execution proof.
struct NodeObservation: Codable, Equatable, Sendable {
    let operationID: String
    let chainID: UInt64
    let endpoint: String
    let operatorID: String
    let nodeVersion: String
    let reportedState: SubmissionState
    let observedAt: Date
    let reportedFinalPeriod: UInt64?
}
/// Explicit operational trust in Massa Labs HTTPS, not independent chain/execution proof.
struct TrustedMassaRPCResolution: Codable, Equatable, Sendable {
    static let policyID = "massa-labs-mainnet-rpc-v1"
    static let endpoint = "https://mainnet.massa.net/api/v2"
    struct Report: Codable, Equatable, Sendable {
        let observation: NodeObservation
        let sourcePublicKey: String
        let sourceAddress: String
        let content: Data
    }
    let policy: String
    let acceptedAt: Date
    let reports: [Report]
    func validate(for draft: ReviewedTransfer, now: Date? = nil) throws {
        try draft.validate()
        guard policy == Self.policyID, reports.count == 2,
              let outcome = reports.first?.observation.reportedState,
              outcome == .finalized || outcome == .failed else { throw SendFailure.response }
        for report in reports {
            let node = report.observation
            guard node.endpoint == Self.endpoint, node.operatorID == "massa-labs",
                  node.chainID == MassaEnvironment.mainnet.chainID, MainnetProtocolCompatibility.supports(node.nodeVersion),
                  node.operationID == draft.operationID, node.reportedState == outcome,
                  report.sourcePublicKey == draft.wallet.publicKey, report.sourceAddress == draft.wallet.address,
                  report.content == draft.content,
                  acceptedAt.timeIntervalSince(node.observedAt) >= 0,
                  acceptedAt.timeIntervalSince(node.observedAt) <= 20 else { throw SendFailure.response }
        }
        guard reports[1].observation.observedAt >= reports[0].observation.observedAt else { throw SendFailure.response }
        if let now {
            guard now.timeIntervalSince(acceptedAt) >= 0, now.timeIntervalSince(acceptedAt) <= 20 else { throw SendFailure.stale }
        }
    }
}
struct ReconciliationAssessment: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        case observed, notFound, expiredHistoryUnavailable, conflictingObservations
        case uncorroboratedTerminal, invalidEvidence, trustedMassaLabs, ownerReviewedHistorical
    }
    let state: SubmissionState
    let reason: Reason
    let checkedAt: Date
    let reportedFinalPeriod: UInt64?
    var reportedState: SubmissionState? = nil
    var observations: [NodeObservation]? = nil
    var terminalClaims: [SubmissionState]? = nil
    var providerResolution: TrustedMassaRPCResolution? = nil
    var historicalResolution: OwnerHistoricalResolution? = nil

    static func combine(_ first: SubmissionState, _ second: SubmissionState, finalPeriod: UInt64?, expiry: UInt64,
                        now: Date = Date(), operationID: String? = nil, observations: [NodeObservation] = []) -> Self {
        // Bare flags do not establish the strict trusted-provider contract. The RPC adapter must
        // additionally match full canonical operation content and supply typed resolution provenance.
        let invalid = observations.contains {
            $0.operationID != operationID || $0.chainID != MassaEnvironment.mainnet.chainID || !MainnetProtocolCompatibility.supports($0.nodeVersion) ||
            now.timeIntervalSince($0.observedAt) < 0 || now.timeIntervalSince($0.observedAt) > 30
        }
        let agrees = first == second
        let terminal = first == .finalized || first == .failed
        // A pending-to-final transition is normal progress, not an opposite terminal outcome.
        // Mixed bundles still resolve nothing; a later complete check may establish the outcome.
        let terminalConflict = terminal && (second == .finalized || second == .failed) && !agrees
        let state: SubmissionState = invalid || !agrees || terminal ? .outcomeUnknown : first
        let reason: Reason = invalid ? .invalidEvidence : !agrees ? (terminalConflict ? .conflictingObservations : .observed) : terminal ? .uncorroboratedTerminal : state != .outcomeUnknown ? .observed : (finalPeriod.map { $0 > expiry } ?? false) ? .expiredHistoryUnavailable : .notFound
        return Self(state: state, reason: reason, checkedAt: now, reportedFinalPeriod: finalPeriod,
                    reportedState: agrees ? first : nil, observations: observations.isEmpty ? nil : observations,
                    terminalClaims: [first, second].filter { $0 == .finalized || $0 == .failed }).retainingHistory(nil)
    }
    static func retainingUnverified(_ record: PendingTransfer) -> Self {
        var claims = record.assessment?.terminalClaims ?? []
        for state in [record.assessment?.reportedState, record.state].compactMap({ $0 })
            where (state == .finalized || state == .failed) && !claims.contains(state) { claims.append(state) }
        let conflict = claims.count > 1 || record.assessment?.reason == .conflictingObservations
        return Self(state: .outcomeUnknown, reason: conflict ? .conflictingObservations : .uncorroboratedTerminal,
                    checkedAt: record.assessment?.checkedAt ?? record.draft.reviewedAt,
                    reportedFinalPeriod: record.assessment?.reportedFinalPeriod,
                    reportedState: record.state, observations: record.assessment?.observations,
                    terminalClaims: claims.isEmpty ? nil : claims)
    }

    func retainingHistory(_ previous: Self?) -> Self {
        let reports = (previous?.terminalClaims ?? []) + [previous?.reportedState, reportedState].compactMap { $0 } + (terminalClaims ?? []) +
            (previous?.observations ?? []).map(\.reportedState) + (observations ?? []).map(\.reportedState)
        var claims: [SubmissionState] = []
        for state in reports where state == .finalized || state == .failed {
            if !claims.contains(state) { claims.append(state) }
        }
        let conflict = claims.count > 1 || previous?.reason == .conflictingObservations || reason == .conflictingObservations
        let history = Array(((previous?.observations ?? []) + (observations ?? [])).suffix(16))
        return Self(state: conflict ? .outcomeUnknown : state,
                    reason: conflict ? .conflictingObservations : reason, checkedAt: checkedAt,
                    reportedFinalPeriod: reportedFinalPeriod, reportedState: reportedState,
                    observations: history.isEmpty ? nil : history, terminalClaims: claims.isEmpty ? nil : claims,
                    providerResolution: conflict ? nil : providerResolution, historicalResolution: conflict ? nil : historicalResolution)
    }
    /// Interrupted submitting records keep their reports without pretending to establish a terminal result.
    func asUnresolved() -> Self {
        Self(state: .outcomeUnknown, reason: reason, checkedAt: checkedAt,
             reportedFinalPeriod: reportedFinalPeriod, reportedState: reportedState,
             observations: observations, terminalClaims: terminalClaims)
    }
    func resolvedOutcome(for draft: ReviewedTransfer) -> SubmissionState? {
        guard state == .finalized || state == .failed, reportedState == state,
              (terminalClaims ?? []).allSatisfy({ $0 == state }),
              (observations ?? []).allSatisfy({ $0.reportedState != .finalized && $0.reportedState != .failed || $0.reportedState == state }) else { return nil }
        if reason == .ownerReviewedHistorical {
            guard state == .finalized, providerResolution == nil, let receipt = historicalResolution,
                  checkedAt == receipt.acceptedAt, (try? receipt.validate(for: draft)) != nil else { return nil }
        } else {
            guard reason == .trustedMassaLabs, historicalResolution == nil, let resolution = providerResolution,
                  checkedAt == resolution.acceptedAt, (try? resolution.validate(for: draft)) != nil,
                  resolution.reports.allSatisfy({ $0.observation.reportedState == state }),
                  Array((observations ?? []).suffix(2)) == resolution.reports.map(\.observation) else { return nil }
        }
        return state
    }
    var message: String {
        switch reason {
        case .ownerReviewedHistorical: L("Accepted after your authenticated review of official Explorer evidence. This is not RPC confirmation or independent consensus verification.")
        case .trustedMassaLabs: L("Confirmed by Massa Mainnet RPC. This relies on the Massa Labs provider, not independent cryptographic verification.")
        case .observed: L("Status is reported by the Mainnet node; it is not an independent archival proof.")
        case .notFound: L("The node has no reliable historical result for this operation. Not found does not mean rejected. Do not repeat this payment.")
        case .expiredHistoryUnavailable: L("The node reports execution past expiry, but the historical outcome is unverified. It may already have executed. Keep this operation locked and seek archival confirmation.")
        case .conflictingObservations: L("Mainnet observations disagree. The original operation remains locked. Obtain reliable archival evidence before considering another payment.")
        case .uncorroboratedTerminal: L("The stored terminal report has not passed the Massa Labs RPC checks. Keep this payment locked until its original operation can be checked.")
        case .invalidEvidence: L("The operation evidence is stale or inconsistent. No source lock was released.")
        }
    }
}
extension TransferNetworking {
    func reconciliation(for draft: ReviewedTransfer) async throws -> ReconciliationAssessment {
        let state = try await lookup(operationID: draft.operationID)
        return .combine(state, state, finalPeriod: nil, expiry: draft.expiry)
    }
}
