import Foundation
import Observation
import UserNotifications
@preconcurrency import BackgroundTasks

@MainActor protocol BalanceNotificationDelivering {
    func permission() async -> Bool
    func requestPermission() async -> Bool
    func deliver(identifier: String) async throws
    func clear()
}

@MainActor final class LocalBalanceNotificationDelivery: BalanceNotificationDelivering {
    private let center = UNUserNotificationCenter.current()
    func permission() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
    func deliver(identifier: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = L("Wallet balance changed")
        content.body = L("Open Massive X to view the updated balance.")
        // No wallet name, address, amount, key or badge on the lock screen.
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
    func clear() {
        // The app schedules only balance notifications. No other app's notifications are accessible.
        center.removeAllPendingNotificationRequests(); center.removeAllDeliveredNotifications()
    }
}

/// Final balances only. A baseline is not a transaction history or a promise of background delivery.
@MainActor @Observable final class BalanceNotifications {
    static let shared = BalanceNotifications()
    private(set) var enabled: Bool
    private(set) var authorized = false
    private(set) var deliveryFailed = false
    private var baselines: [String: String]
    private var epoch = 0
    private let defaults: UserDefaults
    private let delivery: any BalanceNotificationDelivering
    private let scheduleBackground: (Bool) -> Void
    init(defaults: UserDefaults = .standard,
         delivery: any BalanceNotificationDelivering = LocalBalanceNotificationDelivery(),
         scheduleBackground: @escaping (Bool) -> Void = { BackgroundBalanceRefresh.configure(enabled: $0) }) {
        self.defaults = defaults; self.delivery = delivery; self.scheduleBackground = scheduleBackground
        enabled = defaults.bool(forKey: "balance-notifications.enabled")
        baselines = defaults.dictionary(forKey: "balance-notifications.baselines") as? [String: String] ?? [:]
    }
    func refreshPermission() async { authorized = await delivery.permission() }
    func setEnabled(_ value: Bool) async {
        epoch += 1
        enabled = value; defaults.set(value, forKey: "balance-notifications.enabled")
        // Every enable starts a fresh baseline, avoiding alerts for changes during disabled periods.
        baselines = [:]; persist()
        if !value { delivery.clear(); scheduleBackground(false); return }
        let token = epoch
        authorized = await delivery.requestPermission()
        guard token == epoch, enabled else { return }
        scheduleBackground(true)
    }
    func observe(walletID: String, balance: MASAmount) async {
        guard enabled else { return }
        let previous = baselines.updateValue(String(balance.nano), forKey: walletID)
        persist()
        guard let previous, previous != String(balance.nano) else { return }
        let token = epoch
        let permitted = await delivery.permission()
        guard enabled, token == epoch, permitted, baselines[walletID] == String(balance.nano) else { return }
        authorized = permitted
        do {
            // Stable per-wallet identifier replaces rather than duplicates a pending alert.
            try await delivery.deliver(identifier: "balance." + walletID)
            if !enabled || epoch != token { delivery.clear() }
            deliveryFailed = false
        } catch { deliveryFailed = true }
    }
    func removeWallets(_ ids: Set<String>) {
        epoch += 1
        for id in ids { baselines[id] = nil }
        persist(); delivery.clear()
    }
    private func persist() { defaults.set(baselines, forKey: "balance-notifications.baselines") }
}

@MainActor enum BackgroundBalanceRefresh {
    static let identifier = "com.massivex.wallet.balance-refresh"
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let work = Task { @MainActor in
                let notifications = BalanceNotifications.shared
                guard notifications.enabled else { task.setTaskCompleted(success: true); return }
                configure(enabled: true)
                let wallets = WalletManager(balanceChanged: { id, amount in await notifications.observe(walletID: id, balance: amount) })
                for wallet in wallets.activeWallets {
                    if Task.isCancelled { break }
                    await wallets.refreshBalance(wallet.id)
                }
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }
    static func configure(enabled: Bool) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        // iOS may reject or defer requests; foreground refresh remains available.
        try? BGTaskScheduler.shared.submit(request)
    }
}
