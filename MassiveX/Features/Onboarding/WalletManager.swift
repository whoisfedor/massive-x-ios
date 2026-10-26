import Foundation
import Observation
import LocalAuthentication

struct ManagedWallet: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case owned, watchOnly }
    enum Safety: String, Codable { case normal, archivedPreview }
    enum Storage: String, Codable { case current, legacy }
    let id: String
    var name: String
    let address: String
    let publicKey: String?
    let kind: Kind
    var network: String
    var backupAcknowledged: Bool
    var safety: Safety
    var storage: Storage
    let creationJournalID: UUID?
    var isQuarantined: Bool { safety != .normal }
    init(id: String, name: String, address: String, publicKey: String?, kind: Kind, network: String,
         backupAcknowledged: Bool, safety: Safety = .normal, storage: Storage = .current, creationJournalID: UUID? = nil) {
        self.id = id; self.name = name; self.address = address; self.publicKey = publicKey; self.kind = kind
        self.network = network; self.backupAcknowledged = backupAcknowledged; self.safety = safety; self.storage = storage; self.creationJournalID = creationJournalID
    }
    private enum CodingKeys: String, CodingKey { case id, name, address, publicKey, kind, network, backupAcknowledged, safety, storage, creationJournalID }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        address = try c.decode(String.self, forKey: .address); publicKey = try c.decodeIfPresent(String.self, forKey: .publicKey)
        kind = try c.decode(Kind.self, forKey: .kind); network = try c.decode(String.self, forKey: .network)
        backupAcknowledged = try c.decode(Bool.self, forKey: .backupAcknowledged)
        safety = try c.decodeIfPresent(Safety.self, forKey: .safety) ?? .archivedPreview
        storage = try c.decodeIfPresent(Storage.self, forKey: .storage) ?? .legacy
        creationJournalID = try c.decodeIfPresent(UUID.self, forKey: .creationJournalID)
    }
    var shortAddress: String { String(address.prefix(6)) + "…" + String(address.suffix(6)) }
}

@MainActor private final class BoundWalletMetadata: WalletMetadataStoring {
    var record: WalletRecord?
    let changed: (WalletRecord) -> Void
    init(record: WalletRecord? = nil, changed: @escaping (WalletRecord) -> Void = { _ in }) {
        self.record = record; self.changed = changed
    }
    func load() -> WalletRecord? { record }
    func save(_ record: WalletRecord) { self.record = record; changed(record) }
}

/// Public, immutable review. A backup acknowledgement is not recovery evidence.
struct WalletRemovalPlan: Equatable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: UUID
    let revision: UInt64
    let wallets: [ManagedWallet]
    let selectedID: String?
    var description: String { "WalletRemovalPlan(<redacted>)" }
    var debugDescription: String { description }
    var owned: [ManagedWallet] { wallets.filter { $0.kind == .owned } }
    var watched: [ManagedWallet] { wallets.filter { $0.kind == .watchOnly } }
}
enum WalletRemovalFailure: Error, Equatable {
    case changed, cancelled, authentication, expired, privacy, incomplete
    var message: String {
        switch self {
        case .changed: L("The wallet list changed. Review it again before logging out.")
        case .cancelled: L("Authentication cancelled. No wallets were removed.")
        case .authentication: L("Device-owner authentication failed. No wallets were removed.")
        case .expired: L("Removal authorization expired. Review the wallet list and authenticate again.")
        case .privacy: L("Return to the active app and stop screen capture before continuing.")
        case .incomplete: L("Wallet logout incomplete. Its record was retained; verify access before retrying.")
        }
    }
}
/// Public catalog only. Every owned wallet has a distinct protected service; watch-only has none.
@MainActor @Observable final class WalletManager {
    static let legacyID = LegacyWalletMigration.legacyID
    static func keychainService(_ id: String) -> String {
        "com.massivex.mainnet.wallet." + id
    }
    private struct Catalog: Codable { var wallets: [ManagedWallet]; var selectedID: String?; var hiddenArchives: [ManagedWallet]? = nil }
    private var hiddenArchives: [ManagedWallet] = []
    private(set) var wallets: [ManagedWallet] = []
    private(set) var selectedID: String?
    private(set) var backup: WalletOnboarding?
    private(set) var isBusy = false
    private(set) var message: String?
    private(set) var duplicateID: String?
    private(set) var balances: [String: MainnetBalance] = [:]
    private(set) var balanceErrors: [String: String] = [:]
    private(set) var loadingBalances: Set<String> = []
    private let defaults: UserDefaults
    private let stores: (String) -> any TestAccountSecretStore
    private let authentication: () -> any WalletAuthenticating
    private let clipboardFactory: (String) -> any BackupClipboard
    @ObservationIgnored private var backupClipboards: [String: any BackupClipboard] = [:]
    private let client: any MainnetReading
    private let balanceChanged: (String, MASAmount) async -> Void
    private let walletsRemoved: (Set<String>) -> Void
    private(set) var removalPlan: WalletRemovalPlan?
    private(set) var removalBusy = false
    private(set) var removalFailure: WalletRemovalFailure?
    @ObservationIgnored private var removalAuthentication: (any WalletAuthenticating)?
    @ObservationIgnored private var removalGeneration: UInt64 = 0
    @ObservationIgnored private var catalogRevision: UInt64 = 0
    @ObservationIgnored private var removalActive = false
    @ObservationIgnored private var removalCaptured = false
    @ObservationIgnored private var removalForeground: CheckedContinuation<Void, any Error>?
    @ObservationIgnored private var removalForegroundTimeout: Task<Void, Never>?
    private let removalClock: () -> TimeInterval
    private var catalogEpoch = 0
    private var catalogBlocked = false
    private let catalogKey = "mainnet.wallet-catalog.v1"
    private let legacyStores: (String) -> any TestAccountSecretStore
    private var lastAttempt: [String: Date] = [:]
    private(set) var lastUpdated: [String: Date] = [:]
    var selected: ManagedWallet? { activeWallets.first { $0.id == selectedID } }
    var activeWallets: [ManagedWallet] { wallets.filter { !$0.isQuarantined } }
    var archivedWallets: [ManagedWallet] { hiddenArchives }
    init(defaults: UserDefaults = .standard,
         stores: @escaping (String) -> any TestAccountSecretStore = { TestAccountKeychain(service: WalletManager.keychainService($0)) },
         legacyStores: @escaping (String) -> any TestAccountSecretStore = { TestAccountKeychain(service: LegacyWalletMigration.service($0), account: LegacyWalletMigration.account) },
         authentication: @escaping () -> any WalletAuthenticating = { LocalWalletAuthentication() },
         clipboardFactory: @escaping (String) -> any BackupClipboard = { _ in LocalBackupClipboard() },
         client: any MainnetReading = MainnetRPC(),
         balanceChanged: @escaping (String, MASAmount) async -> Void = { id, amount in await BalanceNotifications.shared.observe(walletID: id, balance: amount) },
         removalClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         walletsRemoved: @escaping (Set<String>) -> Void = { BalanceNotifications.shared.removeWallets($0); MainnetHistory.shared.clear() }) {
        self.defaults = defaults; self.stores = stores; self.legacyStores = legacyStores; self.authentication = authentication; self.clipboardFactory = clipboardFactory; self.client = client; self.balanceChanged = balanceChanged; self.walletsRemoved = walletsRemoved; self.removalClock = removalClock
        if let data = defaults.data(forKey: catalogKey) {
            if let saved = try? JSONDecoder().decode(Catalog.self, from: data),
               (saved.hiddenArchives ?? []).allSatisfy(\.isQuarantined), Self.valid(saved.wallets + (saved.hiddenArchives ?? [])) {
                let combined = saved.wallets + (saved.hiddenArchives ?? [])
                hiddenArchives = combined.filter(\.isQuarantined)
                wallets = combined.filter { !$0.isQuarantined }
                selectedID = activeWallets.contains { $0.id == saved.selectedID } ? saved.selectedID : activeWallets.first?.id
                persist()
            } else {
                catalogBlocked = true
                message = "The wallet list could not be read. Existing keys were not changed. Restore public metadata before adding wallets."
            }
        } else {
            do {
                let old = try LegacyWalletMigration.load(defaults)
                guard Self.valid(old) else { throw MassaCoreError.invalidEncoding }
                hiddenArchives = old; wallets = []; selectedID = nil
                persist()
            } catch {
                catalogBlocked = true
                message = "Previous wallet metadata could not be read. Nothing was deleted or promoted."
            }
        }
        configureBackup()
    }
    private static func valid(_ items: [ManagedWallet]) -> Bool {
        guard Set(items.map(\.id)).count == items.count, Set(items.map(\.address)).count == items.count else { return false }
        return items.allSatisfy {
            guard ($0.id == legacyID || UUID(uuidString: $0.id) != nil), ($0.isQuarantined ? $0.network == "Archived preview" : $0.network == "Mainnet" && $0.storage == .current && !KnownUnsafeWallets.addresses.contains($0.address)),
                  !$0.name.isEmpty, $0.name.count <= 40,
                  (try? MassaPublicAccount.validateUserAddress($0.address)) != nil else { return false }
            if $0.kind == .watchOnly { return $0.publicKey == nil && !$0.backupAcknowledged }
            guard let publicKey = $0.publicKey,
                  let account = try? MassaPublicAccount(rawPublicKey: MassaCodec.decode(publicKey, prefix: "P")) else { return false }
            return account.address == $0.address
        }
    }
    private func persist() {
        // Every catalog/selection/backup-acknowledgement mutation revokes the reviewed deletion set.
        let hadReview = removalPlan != nil
        cancelRemovalReview()
        if hadReview { removalFailure = .changed }
        persistCatalog()
    }
    private func persistCatalog() {
        catalogRevision &+= 1
        guard !catalogBlocked, let data = try? JSONEncoder().encode(Catalog(wallets: wallets, selectedID: selectedID, hiddenArchives: hiddenArchives)) else { return }
        defaults.set(data, forKey: catalogKey)
    }
    private func configureBackup() {
        backup?.close(); backup = nil
        guard let selected else { return }
        backup = makeBackup(selected)
    }
    func archivedBackup(_ id: String) -> WalletOnboarding? {
        guard let archived = archivedWallets.first(where: { $0.id == id }) else { return nil }
        return makeBackup(archived)
    }
    private func makeBackup(_ selected: ManagedWallet) -> WalletOnboarding? {
        guard selected.kind == .owned, let publicKey = selected.publicKey,
              let account = try? MassaPublicAccount(rawPublicKey: MassaCodec.decode(publicKey, prefix: "P")) else { return nil }
        let metadata = BoundWalletMetadata(record: WalletRecord(account, backupAcknowledged: selected.backupAcknowledged)) { [weak self] record in
            guard let self, let index = self.wallets.firstIndex(where: { $0.id == selected.id }),
                  record.address == selected.address, record.publicKey == selected.publicKey else { return }
            self.wallets[index].backupAcknowledged = record.backupAcknowledged
            self.persist()
        }
        // Retain only pasteboard counter/expiry ownership, never the copied key, across selection.
        if backupClipboards[selected.id] == nil { backupClipboards[selected.id] = clipboardFactory(selected.id) }
        return WalletOnboarding(store: selected.storage == .legacy ? legacyStores(selected.id) : stores(selected.id),
            authentication: authentication(), metadata: metadata, clipboard: backupClipboards[selected.id]!)
    }
    func select(_ id: String) {
        guard activeWallets.contains(where: { $0.id == id }) else { return }
        if selectedID != id { selectedID = id; configureBackup(); persist() }
        duplicateID = nil
    }
    func rename(_ id: String, name: String) {
        let cleaned = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !cleaned.isEmpty, let index = wallets.firstIndex(where: { $0.id == id }) else { return }
        wallets[index].name = cleaned; persist()
    }
    private func checkDuplicate(_ address: String) -> Bool {
        guard let existing = (wallets + hiddenArchives).first(where: { $0.address == address }) else { return false }
        if existing.isQuarantined {
            message = "This address belongs to an archived unsafe preview account. It cannot be promoted or offered for funding."
            return true
        }
        duplicateID = existing.id
        message = "This address is already added. Select the existing wallet instead."
        return true
    }
    func dismissDuplicate() { duplicateID = nil }
    func addOwned(privateKey: String? = nil, name: String = "", active: Bool, captured: Bool, creationJournalID: UUID? = nil) async -> Bool {
        guard !catalogBlocked, !isBusy else { return false }
        message = nil; duplicateID = nil
        if let privateKey {
            guard let account = try? MassaTestAccount(importing: privateKey), let identity = try? account.publicAccount else {
                message = OnboardingError.invalidKey.message; return false
            }
            if KnownUnsafeWallets.addresses.contains(identity.address) {
                message = "This is a known public test key. It cannot be used as a Mainnet wallet."
                return false
            }
            if checkDuplicate(identity.address) { return false }
        }
        isBusy = true
        defer { isBusy = false; pendingCreation = nil }
        let id = UUID().uuidString
        let draft = WalletOnboarding(store: stores(id), authentication: authentication(), metadata: BoundWalletMetadata())
        pendingCreation = draft
        draft.updatePrivacy(active: active, captured: captured)
        if let privateKey { await draft.importWallet(privateKey) } else { await draft.create() }
        guard let record = draft.record else { message = draft.message; return false }
        let cleaned = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        wallets.append(ManagedWallet(id: id, name: cleaned.isEmpty ? "Wallet" : cleaned,
            address: record.address, publicKey: record.publicKey, kind: .owned, network: "Mainnet", backupAcknowledged: false, creationJournalID: privateKey == nil ? creationJournalID : nil))
        selectedID = id; persist(); configureBackup()
        message = nil
        return true
    }
    @ObservationIgnored private var pendingCreation: WalletOnboarding?
    func creationPrivacy(active: Bool, captured: Bool, background: Bool = false) {
        pendingCreation?.updatePrivacy(active: active, captured: captured, background: background)
    }
    func cancelCreation() { pendingCreation?.close() }
    func addWatchOnly(address: String, name: String) -> Bool {
        guard !catalogBlocked, !isBusy else { return false }
        message = nil; duplicateID = nil
        let cleanedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? MassaPublicAccount.validateUserAddress(cleanedAddress)) != nil else {
            message = "Enter a valid Massa user address (AU). Only Mainnet read-only tracking is supported."
            return false
        }
        if KnownUnsafeWallets.addresses.contains(cleanedAddress) {
            message = "Known public test addresses are unsafe for Receive and cannot be added as normal wallets."
            return false
        }
        if checkDuplicate(cleanedAddress) { return false }
        let cleanedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let id = UUID().uuidString
        wallets.append(ManagedWallet(id: id, name: cleanedName.isEmpty ? "Wallet" : cleanedName,
            address: cleanedAddress, publicKey: nil, kind: .watchOnly, network: L("Mainnet"), backupAcknowledged: false))
        selectedID = id; persist(); configureBackup()
        return true
    }
    func refreshBalance(_ id: String, force: Bool = false) async {
        guard let wallet = activeWallets.first(where: { $0.id == id }), !loadingBalances.contains(id) else { return }
        let token = catalogEpoch
        if let last = lastAttempt[id], Date().timeIntervalSince(last) < (force ? 2 : 15) { return }
        lastAttempt[id] = Date()
        loadingBalances.insert(id); balanceErrors[id] = nil
        defer { loadingBalances.remove(id) }
        do {
            let balance = try await client.balance(for: wallet.address)
            guard !Task.isCancelled, token == catalogEpoch, activeWallets.contains(where: { $0.id == id }),
                  balance.address == wallet.address, let amount = try? MASAmount(balance.finalBalance) else { return }
            balances[id] = balance; lastUpdated[id] = Date()
            await balanceChanged(id, amount)
        }
        catch { guard token == catalogEpoch else { return }; balanceErrors[id] = (error as? MainnetRPCError)?.userMessage ?? MainnetRPCError.offline.userMessage }
    }
    /// Captures only the selected owned wallet and catalog revision. No deletion capability is returned.
    @discardableResult func beginRemovalReview() -> WalletRemovalPlan? {
        guard !catalogBlocked, !isBusy, !removalBusy, !activeWallets.isEmpty else { return nil }
        cancelRemovalReview(); removalFailure = nil
        guard let selected else { return nil }
        let targets = [selected]
        guard targets.allSatisfy({ $0.storage == .current && UUID(uuidString: $0.id) != nil }) else { removalFailure = .changed; return nil }
        let plan = WalletRemovalPlan(id: UUID(), revision: catalogRevision, wallets: targets, selectedID: selectedID)
        removalPlan = plan
        return plan
    }
    func isCurrentRemovalPlan(_ plan: WalletRemovalPlan) -> Bool {
        removalPlan == plan && plan.revision == catalogRevision && plan.wallets.count == 1 && plan.wallets.first == selected && plan.selectedID == selectedID && !catalogBlocked
    }
    func cancelRemovalReview() {
        removalGeneration &+= 1
        removalPlan = nil
        removalAuthentication?.cancel(); removalAuthentication = nil
        finishRemovalForeground(WalletRemovalFailure.cancelled)
    }
    func removalPrivacy(active: Bool, captured: Bool, background: Bool = false) {
        removalActive = active; removalCaptured = captured
        // Inactivity from the system authentication prompt is allowed only until foreground returns.
        if background || captured {
            cancelRemovalReview(); removalFailure = .privacy
        } else if active { finishRemovalForeground() }
    }
    private func finishRemovalForeground(_ error: (any Error)? = nil) {
        let continuation = removalForeground; removalForeground = nil
        removalForegroundTimeout?.cancel(); removalForegroundTimeout = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
    private func awaitRemovalForeground(_ generation: UInt64) async throws {
        guard generation == removalGeneration, !removalCaptured else { throw WalletRemovalFailure.privacy }
        if removalActive { return }
        try await withCheckedThrowingContinuation { continuation in
            removalForeground = continuation
            removalForegroundTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.finishRemovalForeground(WalletRemovalFailure.privacy)
            }
        }
    }
    func removalBackup(_ plan: WalletRemovalPlan, walletID: String) -> WalletOnboarding? {
        guard !removalBusy, isCurrentRemovalPlan(plan), let wallet = plan.owned.first(where: { $0.id == walletID }) else { return nil }
        return makeBackup(wallet)
    }
    func canAuthorizeRemoval(_ plan: WalletRemovalPlan) -> Bool {
        isCurrentRemovalPlan(plan)
    }
    /// Fresh authentication is evaluated and consumed inside this operation; no Boolean/token can bypass it.
    @discardableResult func removeCurrentWallets(_ plan: WalletRemovalPlan, acknowledged: Bool = false) async -> Bool {
        guard !removalBusy else { return false }
        guard !isBusy, isCurrentRemovalPlan(plan) else { removalFailure = .changed; return false }
        guard removalActive, !removalCaptured else { removalFailure = .privacy; return false }
        guard acknowledged, canAuthorizeRemoval(plan) else { return false }
        removalBusy = true; removalFailure = nil
        let generation = removalGeneration, started = removalClock(), auth = authentication()
        removalAuthentication = auth
        defer { removalBusy = false; auth.cancel(); removalAuthentication = nil }
        do {
            let context = try await auth.authorize(reason: L(plan.owned.isEmpty ? "Authorize removal of this watch-only wallet." : "Authorize removal of this wallet’s local signing key."))
            defer { context.invalidate() }
            try await awaitRemovalForeground(generation)
            guard !Task.isCancelled, generation == removalGeneration, !isBusy, isCurrentRemovalPlan(plan), canAuthorizeRemoval(plan) else { throw WalletRemovalFailure.changed }
            guard removalActive, !removalCaptured else { throw WalletRemovalFailure.privacy }
            guard (0...30).contains(removalClock() - started) else { throw WalletRemovalFailure.expired }
            // Consume the exact reviewed set once. The synchronous deletion loop has no actor suspension.
            removalPlan = nil; removalGeneration &+= 1
            let authorizedGeneration = removalGeneration
            catalogEpoch += 1; pendingCreation?.close(); backup?.close(); backup = nil
            var removed = Set<String>()
            for wallet in plan.wallets {
                do {
                    guard !Task.isCancelled, removalGeneration == authorizedGeneration, removalActive, !removalCaptured else { throw WalletRemovalFailure.privacy }
                    guard (0...30).contains(removalClock() - started) else { throw WalletRemovalFailure.expired }
                    if wallet.kind == .owned { try stores(wallet.id).delete() }
                    // Explicit authenticated wallet deletion still clears its own copied item.
                    backupClipboards.removeValue(forKey: wallet.id)?.clearOwned()
                    removed.insert(wallet.id)
                    wallets.removeAll { $0.id == wallet.id }
                    if selectedID == wallet.id { selectedID = nil }
                    // Keep records for every failed/unattempted exact slot. Missing items are idempotent success.
                    persistCatalog()
                } catch { removalFailure = .incomplete; break }
            }
            for id in removed { balances[id] = nil; balanceErrors[id] = nil; lastUpdated[id] = nil; lastAttempt[id] = nil; loadingBalances.remove(id) }
            if !removed.isEmpty { walletsRemoved(removed) }
            if !activeWallets.contains(where: { $0.id == selectedID }) { selectedID = activeWallets.first?.id }
            persistCatalog(); configureBackup()
            if removed == Set(plan.wallets.map(\.id)) { message = nil; return true }
            message = WalletRemovalFailure.incomplete.message
            return false
        } catch {
            if generation != removalGeneration, removalFailure == .privacy || removalFailure == .changed { /* Keep the concrete invalidation reason. */ }
            else if let failure = error as? WalletRemovalFailure { removalFailure = failure }
            else if (error as? OnboardingError) == .cancelled || (error as? LAError)?.code == .userCancel { removalFailure = .cancelled }
            else { removalFailure = .authentication }
            // A denied, cancelled, stale or failed attempt cannot leave reusable approval/evidence.
            cancelRemovalReview()
            return false
        }
    }
}
