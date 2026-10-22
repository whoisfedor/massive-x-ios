import Foundation
import LocalAuthentication
import Observation
import Security
import UIKit

@MainActor protocol WalletAuthenticating {
    func authorize(reason: String) async throws -> LAContext
    func cancel()
}

@MainActor final class LocalWalletAuthentication: WalletAuthenticating {
    private var pending: LAContext?
    func authorize(reason: String) async throws -> LAContext {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        pending = context
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw OnboardingError.authentication
            }
            return context
        } catch {
            context.invalidate()
            pending = nil
            if let error = error as? LAError, [.userCancel, .appCancel, .systemCancel].contains(error.code) {
                throw OnboardingError.cancelled
            }
            throw OnboardingError.authentication
        }
    }
    func cancel() { pending?.invalidate(); pending = nil }
}

/// Optional user-authorized export only. Never reads another app's clipboard contents.
@MainActor protocol BackupClipboard {
    func write(_ key: String, expires: Date)
    func clearOwned()
}

@MainActor final class LocalBackupClipboard: BackupClipboard {
    private var ownedChange: Int?
    private let board: UIPasteboard
    init(board: UIPasteboard = .general) { self.board = board }
    func write(_ key: String, expires: Date) {
        board.setItems([["public.utf8-plain-text": key]], options: [.localOnly: true, .expirationDate: expires])
        ownedChange = board.changeCount
    }
    func clearOwned() {
        guard let ownedChange else { return }
        // Do not erase a newer clipboard item copied by the user.
        if board.changeCount == ownedChange { board.items = [] }
        self.ownedChange = nil
    }
}

/// Public identity and acknowledgement only. No key material may enter this record.
struct WalletRecord: Codable, Equatable {
    let publicKey: String
    let address: String
    var backupAcknowledged: Bool
    init(_ account: MassaPublicAccount, backupAcknowledged: Bool = false) {
        publicKey = account.publicKey; address = account.address
        self.backupAcknowledged = backupAcknowledged
    }
    func validated() throws -> WalletRecord {
        let derived = try MassaPublicAccount(rawPublicKey: MassaCodec.decode(publicKey, prefix: "P"))
        guard derived.address == address else { throw OnboardingError.identityMismatch }
        return self
    }
}

@MainActor protocol WalletMetadataStoring {
    func load() -> WalletRecord?
    func save(_ record: WalletRecord)
}

@MainActor final class WalletPreferences: WalletMetadataStoring {
    private let defaults: UserDefaults
    private let key = "mainnet.public-wallet-record.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> WalletRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WalletRecord.self, from: data).validated()
    }
    func save(_ record: WalletRecord) {
        // The Codable schema contains public fields only; the private key stays in Keychain.
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: key) }
    }
}

enum OnboardingError: Error {
    case authentication, cancelled, privacyBlocked, invalidKey, missingKey, alreadyExists
    case identityMismatch, wrongRecoveryKey, backupRequired, revealRequired, storage, importUnavailable
    var message: String {
        switch self {
        case .authentication: "Authentication is required. No weaker storage option is available."
        case .cancelled: "Authentication cancelled. No key was revealed or replaced."
        case .privacyBlocked: "Return to the active app and stop screen capture before continuing."
        case .importUnavailable: "A protected wallet already exists. Use Verify your backup to check its key; Import cannot replace it."
        case .invalidKey: "Invalid Massa S1 private key. Check its format and checksum. No input was logged."
        case .missingKey: "Protected key not found. Import your private-key backup; nothing was regenerated."
        case .alreadyExists: "A protected wallet already exists. Use Unlock existing wallet; it was not overwritten."
        case .identityMismatch: "The saved public identity does not match the protected key. Access was stopped."
        case .wrongRecoveryKey: "This key does not recover this wallet. No changes were made."
        case .backupRequired: "Acknowledge your backup before verifying recovery."
        case .revealRequired: "Complete authenticated reveal or copy before acknowledging this backup."
        case .storage: "Protected storage failed. No plaintext or preference fallback was used."
        }
    }
}

/// One protected test-wallet slot. No transaction, network, mnemonic or Receive capability.
@MainActor @Observable final class WalletOnboarding: CustomStringConvertible {
    private(set) var record: WalletRecord?
    private(set) var isBusy = false
    private(set) var isRevealed = false
    private(set) var recoveryVerified = false
    private(set) var needsKeyRestore = false
    private(set) var clipboardActive = false
    private(set) var message: String?
    private(set) var active = false
    private(set) var captured = false
    @ObservationIgnored private var secret: String?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var hasExported = false
    @ObservationIgnored private var foregroundWait: CheckedContinuation<Void, any Error>?
    @ObservationIgnored private var foregroundTimeout: Task<Void, Never>?
    @ObservationIgnored private var clipboardExpiry: Task<Void, Never>?
    private let clipboard: any BackupClipboard
    private let revealDuration: Duration
    private let store: any TestAccountSecretStore
    private let authentication: any WalletAuthenticating
    private let metadata: any WalletMetadataStoring
    nonisolated var description: String { "WalletOnboarding(<redacted>)" }
    var revealedKey: String? { active && !captured && isRevealed ? secret : nil }
    // Recovery checks do not authorize funding or live Receive in this test-only milestone.
    var liveReceiveEnabled: Bool { false }
    init(store: any TestAccountSecretStore = TestAccountKeychain(service: "com.massivex.mainnet.protected-wallet.v1"),
         authentication: any WalletAuthenticating = LocalWalletAuthentication(),
         metadata: any WalletMetadataStoring = WalletPreferences(), clipboard: any BackupClipboard = LocalBackupClipboard(), revealDuration: Duration = .seconds(30)) {
        self.clipboard = clipboard
        self.revealDuration = min(revealDuration, .seconds(30))
        self.store = store; self.authentication = authentication; self.metadata = metadata
        record = metadata.load()
    }
    func updatePrivacy(active: Bool, captured: Bool, background: Bool = false) {
        self.active = active; self.captured = captured
        if !active || captured { conceal(); clearClipboard() }
        // A system authentication prompt may briefly make the scene inactive.
        // Actual backgrounding or capture invalidates pending authorization as well.
        if background || captured {
            epoch += 1; authentication.cancel(); finishForegroundWait(.privacyBlocked)
        } else if active { finishForegroundWait() }
    }
    func close() { updatePrivacy(active: false, captured: captured, background: true) }
    func conceal() { secret = nil; isRevealed = false }
    func screenshotDetected() {
        conceal(); clearClipboard(); epoch += 1; authentication.cancel(); finishForegroundWait(.privacyBlocked)

    }
    private func requirePrivacy(_ token: Int) throws {
        guard active && !captured && token == epoch else { throw OnboardingError.privacyBlocked }
    }
    private func finishForegroundWait(_ error: OnboardingError? = nil) {
        let continuation = foregroundWait; foregroundWait = nil
        foregroundTimeout?.cancel(); foregroundTimeout = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
    private func awaitForeground(_ token: Int) async throws {
        guard token == epoch && !captured else { throw OnboardingError.privacyBlocked }
        if active { return }
        // iOS can complete authentication before delivering the scene's active event.
        // Wait briefly for that event; never publish a key while inactive or after backgrounding.
        try await withCheckedThrowingContinuation { continuation in
            foregroundWait = continuation
            foregroundTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.finishForegroundWait(.privacyBlocked)
            }
        }
    }
    private func run(_ operation: (LAContext, Int) throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true; message = nil
        defer { isBusy = false; authentication.cancel() }
        let token = epoch
        do {
            try requirePrivacy(token)
            let context = try await authentication.authorize(reason: L("Access this Mainnet wallet."))
            defer { context.invalidate() }
            try await awaitForeground(token)
            try requirePrivacy(token)
            try operation(context, token)
        } catch let error as OnboardingError {
            if case .missingKey = error { needsKeyRestore = true }
            message = error.message
        }
        catch TestAccountStorageError.keychain(let status) {
            switch status {
            case errSecDuplicateItem: message = OnboardingError.alreadyExists.message
            case errSecUserCanceled: message = OnboardingError.cancelled.message
            case errSecAuthFailed, errSecInteractionNotAllowed: message = OnboardingError.authentication.message
            default: message = OnboardingError.storage.message
            }
        } catch { message = OnboardingError.storage.message }
    }
    private func publish(_ account: MassaPublicAccount, acknowledged: Bool = false) {
        let value = WalletRecord(account, backupAcknowledged: acknowledged)
        record = value; metadata.save(value); recoveryVerified = false; hasExported = false; needsKeyRestore = false
    }
    private func protectedAccount(_ context: LAContext) throws -> MassaTestAccount {
        guard let bytes = try store.load(context: context) else { throw OnboardingError.missingKey }
        let account = try MassaTestAccount(seed: bytes)
        if let record, try account.publicAccount.publicKey != record.publicKey || account.publicAccount.address != record.address {
            throw OnboardingError.identityMismatch
        }
        return account
    }
    /// Same protected store, identity check and foreground policy as backup, without key export.
    func signTransfer(_ draft: ReviewedTransfer) async throws -> String {
        guard !isBusy else { throw SendFailure.duplicate }
        isBusy = true
        let token = epoch
        defer { isBusy = false; authentication.cancel() }
        do {
            try requirePrivacy(token)
            let context = try await authentication.authorize(reason: L("Authorize the reviewed Mainnet transfer."))
            defer { context.invalidate() }
            try await awaitForeground(token); try requirePrivacy(token)
            let account = try protectedAccount(context)
            guard let record, record.publicKey == draft.wallet.publicKey, record.address == draft.wallet.address else { throw SendFailure.keyUnavailable }
            return try account.signOperation(draft.content, expected: account.publicAccount)
        } catch OnboardingError.cancelled { throw SendFailure.cancelled }
        catch OnboardingError.privacyBlocked { throw SendFailure.privacy }
        catch TestAccountStorageError.keychain(let status) where status == errSecUserCanceled { throw SendFailure.cancelled }
        catch { throw SendFailure.keyUnavailable }
    }
    func create() async {
        conceal()
        await run { _, _ in
            let account = MassaTestAccount()
            try store.saveNew(account.storageData())
            publish(try account.publicAccount)
            message = "Wallet created. It is not backed up yet. Do not fund it."
        }
    }
    func importWallet(_ input: String) async {
        conceal()
        guard record == nil || needsKeyRestore else { message = OnboardingError.importUnavailable.message; return }
        let imported: MassaTestAccount
        do { imported = try MassaTestAccount(importing: input) }
        catch { message = OnboardingError.invalidKey.message; return }
        await run { _, _ in
            if let record, try imported.publicAccount.address != record.address { throw OnboardingError.identityMismatch }
            try store.saveNew(imported.storageData())
            publish(try imported.publicAccount)
            message = "Wallet imported. Complete backup acknowledgement and recovery verification."
        }
    }
    func unlock() async {
        conceal()
        await run { context, _ in
            let account = try protectedAccount(context)
            publish(try account.publicAccount, acknowledged: record?.backupAcknowledged ?? false)
            message = "Protected wallet unlocked. Recovery verification is required for this session."
        }
    }
    func reveal(risksAcknowledged: Bool) async {
        conceal()
        guard risksAcknowledged else { message = "Read and acknowledge the export risks first."; return }
        await run { context, token in
            let account = try protectedAccount(context)
            try requirePrivacy(token)
            secret = try account.backupPrivateKeyEncoding()
            isRevealed = true; hasExported = true

        }
    }
    func clearClipboard() {
        clipboard.clearOwned(); clipboardActive = false
        clipboardExpiry?.cancel(); clipboardExpiry = nil
    }
    func copyForBackup(risksAcknowledged: Bool, clipboardConsent: Bool) async {
        conceal(); clearClipboard()
        guard risksAcknowledged && clipboardConsent else {
            message = "Copy requires acknowledgement of backup risks and explicit clipboard confirmation."
            return
        }
        await run { context, token in
            let account = try protectedAccount(context)
            try requirePrivacy(token)
            clipboard.write(try account.backupPrivateKeyEncoding(), expires: Date().addingTimeInterval(30))
            clipboardActive = true; hasExported = true
            clipboardExpiry = Task { [weak self] in
                do { try await Task.sleep(for: self?.revealDuration ?? .zero) } catch { return }
                self?.clearClipboard()
            }
            message = "Private key copied locally for up to 30 seconds. Leaving this screen clears it. Clipboard access has risks; never paste it into chat. This is not an offline backup."
        }
    }
    func acknowledgeBackup() {
        guard active && !captured, var value = record else { message = OnboardingError.revealRequired.message; return }
        conceal(); value.backupAcknowledged = true; record = value; metadata.save(value)
        message = "Backup acknowledged by you. This does not prove that the backup is correct."
    }
    func verifyRecovery(_ input: String) async {
        conceal(); recoveryVerified = false
        let imported: MassaTestAccount
        do { imported = try MassaTestAccount(importing: input) }
        catch { message = OnboardingError.invalidKey.message; return }
        await run { context, _ in
            let protected = try protectedAccount(context)
            guard try imported.publicAccount == protected.publicAccount else { throw OnboardingError.wrongRecoveryKey }
            recoveryVerified = true
            message = "Recovery verified: the imported key derives the same protected public key and address."
        }
    }
}

@MainActor final class ProtectedTransferSigner: TransferSigning {
    let access: WalletOnboarding
    init(access: WalletOnboarding) { self.access = access }
    func sign(_ draft: ReviewedTransfer) async throws -> String { try await access.signTransfer(draft) }
    func cancel() { access.close() }
}
