import Foundation
import Observation
import Darwin

enum SendFailure: Error, Equatable {
    case historicalEvidence, journalCapacity, creationMinimum, wallet, keyUnavailable, cancelled, stale, changed, recipient, amount, funds, overflow, journal, duplicate, alreadyRecorded, response, network, privacy
    var message: String {
        switch self {
        case .historicalEvidence: L("Historical evidence is unavailable, conflicting or does not match. This payment stays locked.")
        case .journalCapacity: TransferJournalError.capacity.message
        case .creationMinimum: L("Recipient existence is unconfirmed. Send at least 0.001 MAS to cover possible account creation; this cost is deducted from the amount, not added to the fee.")
        case .wallet: L("Select a current owned Mainnet wallet with a valid public identity.")
        case .keyUnavailable: L("The protected signing key is unavailable or does not match. Keep your backup and restore this wallet through wallet management.")
        case .cancelled: L("Authentication cancelled. Nothing was submitted.")
        case .stale, .changed: L("Network parameters or balance changed. Refresh and review again.")
        case .recipient: L("Enter a supported AU recipient. Public unsafe test addresses are not allowed.")
        case .amount: L("Enter a positive MAS amount with at most nine decimal places.")
        case .funds: L("Insufficient available balance for amount and fee.")
        case .overflow: L("The amount exceeds the supported range.")
        case .journal: L("The pending transfer record could not be saved. Sending is locked.")
        case .duplicate: L("An unresolved transfer already exists for this wallet. Check its status before sending again.")
        case .alreadyRecorded: L("This exact operation is already recorded. Wait for the next period, then refresh and review again.")
        case .response, .network: L("Mainnet could not be verified. Check your connection and refresh.")
        case .privacy: L("Return to the active app and stop screen capture before continuing.")
        }
    }
}
enum SendContinuityDisclosure {
    static var text: String { L("This installation may not contain earlier payments. Importing a key or changing devices does not recover missing operation records. Check your previous wallet and records before making a new payment; never repeat an uncertain payment.") }
}
struct SendWallet: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "SendWallet(<redacted>)" }
    var debugDescription: String { description }
    let id: String
    let publicKey: String
    let address: String
    let creationJournalID: UUID?
    init(_ wallet: ManagedWallet) throws {
        guard wallet.kind == .owned, !wallet.isQuarantined, wallet.storage == .current, wallet.network == "Mainnet",
              let key = wallet.publicKey, !KnownUnsafeWallets.addresses.contains(wallet.address),
              let identity = try? MassaPublicAccount(rawPublicKey: MassaCodec.decode(key, prefix: "P")), identity.address == wallet.address else { throw SendFailure.wallet }
        id = wallet.id; publicKey = key; address = wallet.address; creationJournalID = wallet.creationJournalID
    }
    var sourceIdentity: String { String(MassaEnvironment.mainnet.chainID) + ":" + publicKey }
}
struct SendSnapshot: Sendable {
    let fetched: Date
    let chainID: UInt64
    let period: UInt64
    let validity: UInt64
    let fee: MASAmount
    let finalBalance: MASAmount
    let candidateBalance: MASAmount
    let recipientFinal: MASAmount
    let recipientCandidate: MASAmount
    var spendable: MASAmount { min(finalBalance, candidateBalance) }
    func validate(now: Date) throws {
        guard chainID == MassaEnvironment.mainnet.chainID, now.timeIntervalSince(fetched) >= 0,
              now.timeIntervalSince(fetched) <= 20, validity >= 2, period <= UInt64.max - 9 else { throw SendFailure.stale }
    }
}
/// MAIN.5.0/MAIN.5.1 protocol constant, not a live fee. Bound to the verified node version in snapshot().
/// massa-models/config/constants.rs LEDGER_ENTRY_BASE_COST = Amount::const_init(1, 3).
/// transfer_coins subtracts this from the received amount only when creating an absent AU entry.
struct RecipientCredit: Codable, Equatable, Sendable {
    static let ledgerEntryCost = MASAmount(nano: 1_000_000)
    let creationPossible: Bool
    let minimum: MASAmount
    let maximum: MASAmount
    static func make(amount: MASAmount, uncertain: Bool) throws -> Self {
        // Zero is not proof of absence. Cover both possible ledger states without claiming existence.
        if uncertain && amount < ledgerEntryCost { throw SendFailure.creationMinimum }
        return Self(creationPossible: uncertain,
                    minimum: MASAmount(nano: amount.nano - (uncertain ? ledgerEntryCost.nano : 0)), maximum: amount)
    }
    static func make(amount: MASAmount, snapshot: SendSnapshot) throws -> Self {
        try make(amount: amount, uncertain: snapshot.recipientFinal.nano == 0 || snapshot.recipientCandidate.nano == 0)
    }
}
enum SendDisclosure {
    static var text: String { L("Transfers require your review and device-owner authentication.") }
}
/// Immutable review. Contains public operation data only, never signing bytes from Keychain.
struct ReviewedTransfer: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "ReviewedTransfer(<redacted>)" }
    var debugDescription: String { description }
    let wallet: SendWallet
    let recipient: String
    let amount: MASAmount
    let fee: MASAmount
    let total: MASAmount
    let expiry: UInt64
    let reviewedAt: Date
    let content: Data
    let operationID: String
    // Optional only for decoding pre-0.7.4 pending records. New submissions require this review.
    let recipientCredit: RecipientCredit?
    static func make(wallet: SendWallet, recipient: String, amount: String, snapshot: SendSnapshot, now: Date) throws -> Self {
        try snapshot.validate(now: now)
        guard (try? MassaPublicAccount.validateUserAddress(recipient)) != nil, !KnownUnsafeWallets.addresses.contains(recipient) else { throw SendFailure.recipient }
        guard let value = try? MASAmount(amount), value.nano > 0 else { throw SendFailure.amount }
        let credit = try RecipientCredit.make(amount: value, snapshot: snapshot)
        let total = value.nano.addingReportingOverflow(snapshot.fee.nano)
        guard !total.overflow else { throw SendFailure.overflow }
        guard total.partialValue <= snapshot.spendable.nano else { throw SendFailure.funds }
        guard !snapshot.recipientFinal.nano.addingReportingOverflow(value.nano).overflow,
              !snapshot.recipientCandidate.nano.addingReportingOverflow(value.nano).overflow else { throw SendFailure.overflow }
        let expiry = snapshot.period + min(9, snapshot.validity - 1)
        let content = try MassaOperationEncoding.serialized(fee: snapshot.fee, amount: value, expirePeriod: expiry, recipient: recipient)
        return try Self(wallet: wallet, recipient: recipient, amount: value, fee: snapshot.fee, total: MASAmount(nano: total.partialValue), expiry: expiry, reviewedAt: now, content: content,
                        operationID: MassaOperationEncoding.operationID(content: content, publicKey: wallet.publicKey), recipientCredit: credit)
    }
    func validate() throws {
        if let recipientCredit {
            guard try RecipientCredit.make(amount: amount, uncertain: recipientCredit.creationPossible) == recipientCredit else { throw SendFailure.journal }
        }
        let identity = try MassaPublicAccount(rawPublicKey: MassaCodec.decode(wallet.publicKey, prefix: "P"))
        guard identity.address == wallet.address, (try? MassaPublicAccount.validateUserAddress(recipient)) != nil, !KnownUnsafeWallets.addresses.contains(recipient), amount.nano > 0,
              !amount.nano.addingReportingOverflow(fee.nano).overflow,
              amount.nano + fee.nano == total.nano,
              try MassaOperationEncoding.serialized(fee: fee, amount: amount, expirePeriod: expiry, recipient: recipient) == content,
              try MassaOperationEncoding.operationID(content: content, publicKey: wallet.publicKey) == operationID else { throw SendFailure.journal }
    }
}
enum SubmissionState: String, Codable, Sendable {
    case submitting, pending, finalized, failed, outcomeUnknown
    var unresolved: Bool { self == .submitting || self == .pending || self == .outcomeUnknown }
}
struct PendingTransfer: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    // historicalNodeReport is decode-only compatibility, never independently evidenced origin.
    enum Tracking: String, Codable, Sendable { case localSubmission, historicalNodeReport }
    var description: String { "PendingTransfer(<redacted>)" }
    var debugDescription: String { description }
    let draft: ReviewedTransfer
    var state: SubmissionState
    var assessment: ReconciliationAssessment? = nil
    // Optional for v1 arrays and pre-classification v2 records. Missing provenance is not invented.
    var tracking: Tracking? = nil
    var hasTrustedResolution: Bool { assessment?.resolvedOutcome(for: draft) == state }
}
@MainActor protocol TransferJournal {
    var installationID: UUID? { get }
    func read() throws -> [PendingTransfer]
    func write(_ records: [PendingTransfer]) throws
}
extension TransferJournal { var installationID: UUID? { nil } }
@MainActor protocol TransferSigning {
    func sign(_ draft: ReviewedTransfer) async throws -> String
    func cancel()
}
protocol TransferNetworking: Sendable {
    func snapshot(source: String, recipient: String) async throws -> SendSnapshot
    func submit(_ draft: ReviewedTransfer, signature: String) async throws -> String
    func lookup(operationID: String) async throws -> SubmissionState
    func reconciliation(for draft: ReviewedTransfer) async throws -> ReconciliationAssessment
}

@MainActor @Observable final class SendCoordinator {
    enum Phase: Equatable { case draft, review, awaitingAuthentication, submitting, pending, finalized, failed, outcomeUnknown }
    private(set) var phase: Phase = .draft
    private(set) var review: ReviewedTransfer?
    private(set) var pending: [PendingTransfer] = []
    private(set) var failure: SendFailure?
    var message: String? { journalIssue?.message ?? failure?.message }
    private(set) var historicalReview: HistoricalRecoveryReview?
    private var historicalActive = false
    private var historicalCaptured = false
    @ObservationIgnored private var historicalAuthentication: (any WalletAuthenticating)?
    private let historicalClient: any HistoricalEvidenceReading
    private let historicalAuthenticationFactory: () -> any WalletAuthenticating
    private(set) var busy = false
    private(set) var journalIssue: TransferJournalError?
    private var blockedJournal: Bool { journalIssue != nil }
    var journalIdentity: UUID? { blockedJournal ? nil : journal.installationID }
    /// Advisory metadata only. Never authorizes or prohibits a new payment.
    func hasCreationBinding(_ wallet: SendWallet) -> Bool {
        guard let identity = journalIdentity else { return false }
        return wallet.creationJournalID == identity
    }
    private var generation = 0
    private var selection: String?
    private let journal: any TransferJournal
    private let network: any TransferNetworking
    @ObservationIgnored private var signer: (any TransferSigning)?
    init(network: any TransferNetworking = MainnetTransferRPC(), journal: any TransferJournal = FileTransferJournal(),
         historicalClient: any HistoricalEvidenceReading = OfficialHistoricalClient(),
         historicalAuthentication: @escaping () -> any WalletAuthenticating = { LocalWalletAuthentication() }) {
        self.network = network; self.journal = journal; self.historicalClient = historicalClient
        self.historicalAuthenticationFactory = historicalAuthentication
        _ = reloadJournal()
    }
    /// Explicit, validated read/write recovery; never substitutes an empty array for lost history.
    @discardableResult func reloadJournal() -> Bool {
        guard !busy else { return false }
        do {
            var loaded = try journal.read()
            try TransferJournalPolicy.validate(loaded)
            let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.draft.operationID, $0) })
            guard pending.allSatisfy({ byID[$0.draft.operationID]?.draft == $0.draft }) else { throw TransferJournalError.inconsistent }
            for index in loaded.indices {
                // Every record remains a local intent; only validated terminal receipts can resolve it.
                // Old terminal flags and the 8515bfe role cannot authorize a source unlock.
                loaded[index].tracking = .localSubmission
                if (loaded[index].state == .finalized || loaded[index].state == .failed), !loaded[index].hasTrustedResolution {
                    loaded[index].assessment = .retainingUnverified(loaded[index]); loaded[index].state = .outcomeUnknown
                } else if loaded[index].state == .submitting {
                    loaded[index].state = .outcomeUnknown; loaded[index].assessment = loaded[index].assessment?.asUnresolved()
                }
            }
            try journal.write(loaded) // Confirm storage is writable before clearing the fault.
            pending = loaded; journalIssue = nil; failure = nil; invalidateReview()
            if let record = pending.first(where: { $0.draft.wallet.sourceIdentity == selection && !$0.hasTrustedResolution }) { review = record.draft; show(record.state) }
            return true
        } catch { journalIssue = TransferJournalError.classify(error); failure = .journal; return false }
    }

    func select(_ wallet: SendWallet?) {
        guard selection != wallet?.sourceIdentity else { return }
        selection = wallet?.sourceIdentity; invalidateReview()
        if let wallet, let record = unresolved(wallet) { show(record.state); review = record.draft }
    }
    func invalidateReview() {
        historicalAuthentication?.cancel(); historicalAuthentication = nil; historicalReview = nil
        generation += 1; signer?.cancel(); signer = nil; review = nil; phase = .draft; failure = blockedJournal ? .journal : nil
    }
    // Only a durable strict RPC or explicitly owner-reviewed historical receipt resolves an intent.
    func unresolved(_ wallet: SendWallet) -> PendingTransfer? { pending.first { $0.draft.wallet.sourceIdentity == wallet.sourceIdentity && !$0.hasTrustedResolution } }
    private func requireCurrent(_ wallet: SendWallet, token: Int) throws {
        guard generation == token, selection == wallet.sourceIdentity, !Task.isCancelled else { throw SendFailure.cancelled }
    }
    func prepare(wallet: SendWallet, recipient: String, amount: String, now: Date? = nil) async {
        guard !busy else { return }; busy = true; failure = nil
        defer { busy = false }
        let token = generation
        do {
            guard !blockedJournal else { throw SendFailure.journal }
            guard pending.count < TransferJournalPolicy.maximumRecords else { throw SendFailure.journalCapacity }
            guard unresolved(wallet) == nil else { throw SendFailure.duplicate }
            guard (try? MassaPublicAccount.validateUserAddress(recipient)) != nil, !KnownUnsafeWallets.addresses.contains(recipient) else { throw SendFailure.recipient }
            let snapshot = try await network.snapshot(source: wallet.address, recipient: recipient)
            try requireCurrent(wallet, token: token)
            let draft = try ReviewedTransfer.make(wallet: wallet, recipient: recipient, amount: amount, snapshot: snapshot, now: now ?? Date())
            guard !pending.contains(where: { $0.draft.operationID == draft.operationID }) else { throw SendFailure.alreadyRecorded }
            review = draft
            phase = .review
        } catch { if generation == token { review = nil; phase = .draft; failure = error as? SendFailure ?? .response } }
    }
    func confirm(approved: ReviewedTransfer?, signer: any TransferSigning, now: Date = Date()) async {
        guard !busy, phase == .review, let draft = review else { return }
        guard approved == draft else { failure = .changed; return }
        busy = true; failure = nil; self.signer = signer
        let token = generation
        defer { busy = false; self.signer = nil; signer.cancel() }
        var submitted = false
        do {
            guard !blockedJournal else { throw SendFailure.journal }
            guard pending.count < TransferJournalPolicy.maximumRecords else { throw SendFailure.journalCapacity }
            guard unresolved(draft.wallet) == nil else { throw SendFailure.duplicate }
            guard !pending.contains(where: { $0.draft.operationID == draft.operationID }) else { throw SendFailure.alreadyRecorded }
            try requireCurrent(draft.wallet, token: token)
            guard now.timeIntervalSince(draft.reviewedAt) >= 0, now.timeIntervalSince(draft.reviewedAt) <= 20 else { throw SendFailure.stale }
            let fresh = try await network.snapshot(source: draft.wallet.address, recipient: draft.recipient)
            try requireCurrent(draft.wallet, token: token)
            try fresh.validate(now: Date())
            guard fresh.fee == draft.fee, fresh.period < draft.expiry,
                  fresh.spendable >= draft.total,
                  !fresh.recipientFinal.nano.addingReportingOverflow(draft.amount.nano).overflow,
                  !fresh.recipientCandidate.nano.addingReportingOverflow(draft.amount.nano).overflow else { throw SendFailure.changed }
            guard let reviewedCredit = draft.recipientCredit,
                  try RecipientCredit.make(amount: draft.amount, snapshot: fresh) == reviewedCredit else { throw SendFailure.changed }
            try draft.validate()
            phase = .awaitingAuthentication
            let signature = try await signer.sign(draft)
            try requireCurrent(draft.wallet, token: token)
            guard Date().timeIntervalSince(draft.reviewedAt) <= 20 else { throw SendFailure.stale }
            let publicAccount = try MassaPublicAccount(rawPublicKey: MassaCodec.decode(draft.wallet.publicKey, prefix: "P"))
            guard try publicAccount.verify(message: MassaOperationEncoding.canonical(content: draft.content, publicKey: draft.wallet.publicKey), signature: signature) else { throw SendFailure.keyUnavailable }
            // Save BEFORE the only network write. A failed save forbids submission.
            try save(PendingTransfer(draft: draft, state: .submitting))
            phase = .submitting; submitted = true
            let returned = try await network.submit(draft, signature: signature)
            guard returned == draft.operationID else { throw SendFailure.response }
            try save(PendingTransfer(draft: draft, state: .pending))
            if generation == token { phase = .pending }
        } catch {
            if submitted {
                // Even when selection changed, the source-identity lock must survive.
                do { try save(PendingTransfer(draft: draft, state: .outcomeUnknown)) } catch { journalIssue = journalIssue ?? .unavailable }
                if generation == token { phase = .outcomeUnknown }
            } else if generation == token {
                phase = .review; failure = error as? SendFailure ?? .keyUnavailable
                if (error as? SendFailure) == .stale || (error as? SendFailure) == .changed { review = nil; phase = .draft }
            }
        }
    }
    func reconcile(_ record: PendingTransfer) async {
        guard !blockedJournal else { failure = .journal; return }
        guard !busy, pending.contains(where: { $0.draft == record.draft && !$0.hasTrustedResolution }) else { return }; busy = true
        let token = generation
        defer { busy = false }
        do {
            // Not-found/unknown never unlocks a source. No resend exists.
            let assessment = try await network.reconciliation(for: record.draft)
            guard !Task.isCancelled else { return }
            // Bare terminal flags cannot bypass strict canonical/provider validation at this boundary.
            if let resolution = assessment.providerResolution { try resolution.validate(for: record.draft, now: Date()) }
            let isTerminal = assessment.state == .finalized || assessment.state == .failed
            let accepted = isTerminal && assessment.resolvedOutcome(for: record.draft) == nil
                ? ReconciliationAssessment.retainingUnverified(PendingTransfer(draft: record.draft, state: assessment.state, assessment: assessment)) : assessment
            let stored = pending.first { $0.draft.operationID == record.draft.operationID }
            let retained = accepted.retainingHistory(stored?.assessment)
            let state = retained.state
            guard state != .submitting else { throw SendFailure.response }
            try save(PendingTransfer(draft: record.draft, state: state, assessment: retained))
            if retained.resolvedOutcome(for: record.draft) != nil, historicalReview?.draft.operationID == record.draft.operationID {
                historicalReview = nil; historicalAuthentication?.cancel(); historicalAuthentication = nil
            }
            if generation == token, selection == record.draft.wallet.sourceIdentity, review == nil || review?.operationID == record.draft.operationID {
                failure = nil; review = record.draft; show(state)
            }
        } catch { if generation == token, !Task.isCancelled { failure = error as? SendFailure ?? .network } }
    }
    func cancelHistoricalRecovery() { if historicalReview != nil || historicalAuthentication != nil { invalidateReview() } }
    func historicalPrivacy(active: Bool, captured: Bool, background: Bool = false) {
        historicalActive = active; historicalCaptured = captured
        if captured || background { invalidateReview() }
    }
    private func historicalEligible(_ draft: ReviewedTransfer) -> Bool {
        guard let stored = pending.first(where: { $0.draft == draft && !$0.hasTrustedResolution }) else { return false }
        let assessment = stored.assessment
        return assessment?.reason != .conflictingObservations &&
            !(assessment?.terminalClaims ?? []).contains(.failed) &&
            !(assessment?.observations ?? []).contains(where: { $0.reportedState == .failed }) &&
            assessment?.reportedState != .failed
    }
    func prepareHistoricalRecovery(_ record: PendingTransfer) async {
        guard !busy, !blockedJournal, historicalActive, !historicalCaptured,
              selection == record.draft.wallet.sourceIdentity, historicalEligible(record.draft) else { failure = .historicalEvidence; return }
        busy = true; failure = nil; let token = generation
        defer { busy = false }
        do {
            let evidence = try await historicalClient.evidence(for: record.draft)
            try requireCurrent(record.draft.wallet, token: token); try evidence.validate(for: record.draft)
            guard historicalActive, !historicalCaptured else { throw SendFailure.privacy }
            historicalReview = HistoricalRecoveryReview(draft: record.draft, evidence: evidence, reviewedAt: Date())
        } catch { if generation == token { failure = error as? SendFailure ?? .historicalEvidence } }
    }
    func confirmHistoricalRecovery(_ approved: HistoricalRecoveryReview) async {
        guard !busy, !blockedJournal, historicalReview == approved, historicalActive, !historicalCaptured,
              selection == approved.draft.wallet.sourceIdentity, historicalEligible(approved.draft) else { failure = .historicalEvidence; return }
        busy = true; let token = generation; let authentication = historicalAuthenticationFactory()
        historicalAuthentication = authentication
        defer { authentication.cancel(); historicalAuthentication = nil; busy = false }
        do {
            guard (0...300).contains(Date().timeIntervalSince(approved.reviewedAt)) else { throw SendFailure.stale }
            let context = try await authentication.authorize(reason: L("Accept this historical payment result."))
            defer { context.invalidate() }
            // Face ID/passcode can temporarily deactivate the scene. Background/capture still revoke it.
            for _ in 0..<20 {
                try requireCurrent(approved.draft.wallet, token: token)
                guard !historicalCaptured else { throw SendFailure.privacy }
                if historicalActive { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard historicalActive, historicalReview == approved else { throw SendFailure.privacy }
            let authorizedAt = Date()
            let refreshed = try await historicalClient.evidence(for: approved.draft)
            try requireCurrent(approved.draft.wallet, token: token)
            guard historicalActive, !historicalCaptured, refreshed.sameStatement(as: approved.evidence), historicalEligible(approved.draft) else { throw SendFailure.historicalEvidence }
            let receipt = OwnerHistoricalResolution(policy: OwnerHistoricalResolution.policyID, authorizationMethod: "deviceOwnerAuthentication",
                authorizedAt: authorizedAt, acceptedAt: Date(), evidence: refreshed)
            try receipt.validate(for: approved.draft)
            let assessment = ReconciliationAssessment(state: .finalized, reason: .ownerReviewedHistorical,
                checkedAt: receipt.acceptedAt, reportedFinalPeriod: nil, reportedState: .finalized,
                terminalClaims: [.finalized], historicalResolution: receipt)
                .retainingHistory(pending.first(where: { $0.draft == approved.draft })?.assessment)
            guard assessment.resolvedOutcome(for: approved.draft) == .finalized else { throw SendFailure.historicalEvidence }
            try save(PendingTransfer(draft: approved.draft, state: .finalized, assessment: assessment))
            historicalReview = nil; review = approved.draft; failure = nil; phase = .finalized
        } catch {
            if generation == token { if let onboarding = error as? OnboardingError, case .cancelled = onboarding { failure = .cancelled }
                else { failure = (error as? SendFailure) ?? .historicalEvidence } }
        }
    }
    /// Scheduling only, never evidence of execution. Old/expired/pruned intents remain locked.
    var recentUnresolvedOperationID: String? {
        guard !blockedJournal else { return nil }
        return pending.first {
            $0.draft.wallet.sourceIdentity == selection && !$0.hasTrustedResolution &&
            (0...600).contains(Date().timeIntervalSince($0.draft.reviewedAt))
        }?.draft.operationID
    }
    /// Bounded foreground reads preserve the existing strict two-observation receipt acceptance.
    /// This method has no signing/submission/replacement path. Cancellation stops future reads.
    func pollRecentOperation(_ operationID: String,
                             pause: @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(15)) }) async {
        for attempt in 0..<4 {
            guard !Task.isCancelled, recentUnresolvedOperationID == operationID,
                  let record = pending.first(where: { $0.draft.operationID == operationID }) else { return }
            if !busy { await reconcile(record) }
            guard recentUnresolvedOperationID == operationID, attempt < 3 else { return }
            do { try await pause() } catch { return }
        }
    }
    /// Explicit navigation to a NEW draft; cannot unlock or retry an existing intent.
    @discardableResult func beginNewTransfer(for wallet: SendWallet) -> Bool {
        guard !busy, !blockedJournal, selection == wallet.sourceIdentity else { return false }
        guard unresolved(wallet) == nil else { failure = .duplicate; return false }
        invalidateReview(); return true
    }
    private func save(_ record: PendingTransfer) throws {
        var stored = record
        stored.tracking = .localSubmission
        var next = pending.filter { $0.draft.operationID != record.draft.operationID }; next.append(stored)
        guard !blockedJournal else { throw SendFailure.journal }
        do { try TransferJournalPolicy.validate(next); try journal.write(next); pending = next }
        catch TransferJournalError.capacity { throw SendFailure.journalCapacity }
        catch { journalIssue = TransferJournalError.classify(error); throw SendFailure.journal }
    }
    /// Merge-only public restoration. It can restore source locks, never authorize clean continuity
    /// or turn a reported terminal result into verified finality. No key access or network writes.
    func restorePublicOperations(_ file: PublicOperationFile, for wallet: SendWallet) throws {
        guard !busy else { throw SendFailure.duplicate }
        guard !blockedJournal else { throw SendFailure.journal }
        try file.validate(for: wallet)
        var merged = pending
        for draft in file.operations {
            if let existing = merged.first(where: { $0.draft.operationID == draft.operationID }) {
                guard existing.draft == draft else { throw SendFailure.changed }
            } else { merged.append(PendingTransfer(draft: draft, state: .outcomeUnknown, tracking: .localSubmission)) }
        }
        do {
            try TransferJournalPolicy.validate(merged); try journal.write(merged)
            pending = merged; invalidateReview()
            if selection == wallet.sourceIdentity, let record = unresolved(wallet) { review = record.draft; show(record.state) }
        } catch TransferJournalError.capacity { throw SendFailure.journalCapacity }
        catch { journalIssue = TransferJournalError.classify(error); throw SendFailure.journal }
    }
    func supportDetails(_ record: PendingTransfer) -> String {
        // Explicit user sharing only. No key, signature, auth data or wallet catalog is included.
        "Massa Mainnet chain " + String(MassaEnvironment.mainnet.chainID) + "\nOperation: " + record.draft.operationID + "\nExpiry period: " + String(record.draft.expiry) + "\nAmount MAS: " + record.draft.amount.text + "\nFee MAS: " + record.draft.fee.text + "\nTracking: " + (record.tracking?.rawValue ?? "legacy-unspecified") + "\nObserved state: " + record.state.rawValue + "\nEvidence: " + (record.assessment?.reason.rawValue ?? "unavailable") + "\nHistorical outcome is not independently established. Do not treat this as proof of payment or rejection."
    }
    private func show(_ state: SubmissionState) {
        switch state { case .submitting, .outcomeUnknown: phase = .outcomeUnknown; case .pending: phase = .pending; case .finalized: phase = .finalized; case .failed: phase = .failed }
    }
}
