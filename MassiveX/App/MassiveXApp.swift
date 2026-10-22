import SwiftUI
import UserNotifications

enum AppTab: Hashable { case wallet, activity, settings }

@main
struct MassiveXApp: App {
    @UIApplicationDelegateAdaptor(MassiveXApplicationDelegate.self) private var appDelegate
    @State private var languages = AppLanguageSettings.shared
    @State private var notifications = BalanceNotifications.shared
    @AppStorage("appearance") private var appearance = AppAppearance.dark.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wallets = WalletManager()
    @State private var wallet = WalletState()
    @Environment(\.scenePhase) private var phase
    @State private var fiat = FiatSettings()
    @State private var prices = FiatPrices()
    @State private var history = MainnetHistory.shared
    @State private var historyPreferences = HistoryPreferences.shared
    @State private var send = SendCoordinator()
    @State private var selectedTab = AppTab.wallet
    @State private var settingsNavigation = SettingsNavigationState()
    @State private var appIcons = AppIconSettings()
    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                WalletView(state: wallet, selectedTab: $selectedTab)
                    .tabItem { Label(languages.text("Wallet"), systemImage: "wallet.bifold") }.tag(AppTab.wallet)
                ActivityView()
                    .tabItem { Label(languages.text("Activity"), systemImage: "clock.arrow.circlepath") }.tag(AppTab.activity)
                SettingsView(selectedTab: $selectedTab, navigation: $settingsNavigation)
                    .tabItem { Label(languages.text("Settings"), systemImage: "gearshape") }.tag(AppTab.settings)
            }
            .onChange(of: selectedTab) { _, tab in settingsNavigation.tabChanged(settingsSelected: tab == .settings) }
            .environment(\.walletAdded, { selectedTab = .wallet })
            .environment(languages)
            .environment(historyPreferences)
            .environment(send)
            .environment(notifications)
            .environment(\.locale, languages.language.locale)
            .environment(wallets)
            .environment(wallet)
            .environment(fiat)
            .environment(prices)
            .environment(history)
            .onChange(of: wallets.selectedID, initial: true) { _, _ in send.select(wallets.selected.flatMap { try? SendWallet($0) }) }
            .task(id: wallets.selected?.address) { let address = wallets.selected?.address; history.activate(address); if let address { await history.refresh(address) } }
            .task(id: wallets.selectedID) {
                await refreshBalances()
            }
            .task(id: "\(fiat.currency):\(wallets.selectedID ?? "none")") {
                if wallets.selectedID != nil { await prices.refresh(fiat.currency) }
            }
            .task { await appIcons.migrateRemovedSelection() }
            .onAppear {
                wallets.removalPrivacy(active: phase == .active, captured: UIScreen.main.isCaptured)
                if phase == .active, send.journalIssue != nil { send.reloadJournal() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                if send.journalIssue != nil { send.reloadJournal() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                wallets.removalPrivacy(active: phase == .active, captured: UIScreen.main.isCaptured)
            }
            .onChange(of: phase) { _, phase in
                wallets.removalPrivacy(active: phase == .active, captured: UIScreen.main.isCaptured, background: phase == .background)
                if phase == .active, send.journalIssue != nil { send.reloadJournal() }
                if phase == .active { Task { await appIcons.migrateRemovedSelection() } }
                if phase == .active { Task { await notifications.refreshPermission(); await refreshBalances(); await prices.refresh(fiat.currency); if let address = wallets.selected?.address { await history.refresh(address) } } }
                if phase == .background { BackgroundBalanceRefresh.configure(enabled: notifications.enabled) }
            }
            .tint(Theme.accent)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: ThemeSettings.shared.palette)
            .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .dark).colorScheme)
            #if DEBUG
            .fullScreenCover(isPresented: .constant(ProcessInfo.processInfo.arguments.contains("--keychain-security-probe"))) {
                KeychainSecurityProbeView()
            }
            #endif
        }
    }
    @MainActor private func refreshBalances() async {
        let ids = notifications.enabled ? wallets.activeWallets.map(\.id) : wallets.selectedID.map { [$0] } ?? []
        for id in ids { if Task.isCancelled { return }; await wallets.refreshBalance(id) }
    }
}

final class MassiveXApplicationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? .portrait : .allButUpsideDown
    }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BackgroundBalanceRefresh.register()
        return true
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

}
