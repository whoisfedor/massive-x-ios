import SwiftUI

struct LanguageSettingsView: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    @Environment(AppLanguageSettings.self) private var settings
    var body: some View {
        let _ = liveLanguage.language
        List(AppLanguage.allCases) { language in
            Button { settings.select(language) } label: {
                HStack {
                    Text(verbatim: language.name)
                    Spacer()
                    if settings.language == language { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                }.foregroundStyle(.primary).frame(minHeight: 44)
            }.accessibilityIdentifier("language." + language.rawValue).listRowBackground(Theme.surface)
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle(L("Language"))
    }
}

struct BalanceNotificationSettingsView: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    @Environment(BalanceNotifications.self) private var notifications
    @Environment(WalletManager.self) private var wallets
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    var body: some View {
        let _ = liveLanguage.language
        List {
            Section {
                Toggle("Balance-change notifications", isOn: Binding(get: { notifications.enabled }, set: { value in
                    Task {
                        await notifications.setEnabled(value)
                        if value { for wallet in wallets.activeWallets { await wallets.refreshBalance(wallet.id) } }
                    }
                }))
                if notifications.enabled && !notifications.authorized {
                    Text(L("Notifications are not authorized. Enable alerts in iOS Settings."))
                    Button(L("Open iOS Settings")) { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                }
                if notifications.deliveryFailed { Text(L("The latest notification could not be scheduled.")).foregroundStyle(Theme.warning) }
            }.listRowBackground(Theme.surface)
            Section {
                Text(L("The first balance read is a silent baseline. Later final-balance changes can trigger a private local alert for owned and watch-only wallets. No address or amount appears in the alert."))
                Text(L("Refresh occurs while using the app and opportunistically in the background. iOS controls background execution; alerts are not real-time or guaranteed. Keep Background App Refresh enabled in iOS Settings. No remote push service is used."))
            }.font(.footnote).foregroundStyle(.secondary).listRowBackground(Theme.surface)
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle(L("Balance notifications"))
            .task { await notifications.refreshPermission() }
            .onChange(of: phase) { _, value in if value == .active { Task { await notifications.refreshPermission() } } }
    }
}

struct MassaEcosystemView: View {
    @State private var icons = AppIconSettings()
    @Environment(\.scenePhase) private var phase
    @Environment(AppLanguageSettings.self) private var liveLanguage
    var body: some View {
        let _ = liveLanguage.language
        List {
            NavigationLink { AboutView() } label: {
                HStack(spacing: 16) {
                    Image(icons.selected.previewName).resizable().scaledToFit().frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 16)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Massive X").font(.headline)
                        Text(L("Native Massa wallet")).font(.subheadline).foregroundStyle(.secondary)
                        Text(L("About this app")).font(.caption).foregroundStyle(Theme.accent)
                    }
                }.padding(.vertical, 8)
            }.listRowBackground(Theme.surface)
            Section(L("Explore the ecosystem")) {
                ForEach(EcosystemLinks.destinations) { destination in
                    Link(destination: destination.url) {
                        HStack { Text(L(destination.name)); Spacer(); Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary) }
                    }.accessibilityHint(L("Opens an external website. No wallet connection or signing is performed."))
                }
                Text(L("External services have their own terms and privacy practices. Listing is not an endorsement or an integrated wallet feature."))
                    .font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Theme.surface)
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle(L("Massa Ecosystem"))
            .onAppear { icons.refresh() }
            .onChange(of: phase) { _, value in if value == .active { icons.refresh() } }
    }
}

struct EcosystemDestination: Identifiable {
    let name: String
    let url: URL
    var id: String { name }
}
enum EcosystemLinks {
    static let destinations: [EcosystemDestination] = [
        ("Massa Explorer", "https://explorer.massa.net/"),
        ("Dusa", "https://app.dusa.io/"),
        ("Massa Bridge", "https://bridge.massa.net/index"),
        ("EagleFi DEX", "https://eaglefi-dex.deweb.node-master.fr/"),
        ("Official Massa Website", "https://massa.network/")
    ].map { EcosystemDestination(name: $0.0, url: URL(string: $0.1)!) }
}

enum AppIconChoice: String, CaseIterable, Identifiable {
    // Keep the legacy Swift case name for Crimson004; defaultChoice denotes the OS primary.
    case icon001 = "001", icon002 = "002", icon003 = "003", primary = "004"
    var id: String { rawValue }
    static var defaultChoice: Self { .icon001 }
    var iconName: String? {
        switch self {
        case .icon001: nil
        case .primary: "MassiveXIcon004"
        case .icon002, .icon003: "MassiveXIcon" + rawValue
        }
    }
    var previewName: String { "IconPreview" + rawValue }
    var titleKey: String { switch self { case .icon001: "Classic"; case .icon002: "Midnight"; case .icon003: "Aureum"; case .primary: "Crimson" } }
    static func selected(_ name: String?) -> Self {
        // Retain the former explicitly selected Classic identifier as a compatible alias.
        if name == "MassiveXIcon001" { return .icon001 }
        return allCases.first { $0.iconName == name } ?? .defaultChoice
    }
}
@MainActor protocol AppIconSwitching {
    var supported: Bool { get }
    var current: String? { get }
    func change(_ name: String?) async throws
}
@MainActor struct SystemAppIconSwitcher: AppIconSwitching {
    var supported: Bool { UIApplication.shared.supportsAlternateIcons }
    var current: String? { UIApplication.shared.alternateIconName }
    func change(_ name: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            UIApplication.shared.setAlternateIconName(name) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
@MainActor @Observable final class AppIconSettings {
    private let system: any AppIconSwitching
    private(set) var selected: AppIconChoice
    private(set) var busy = false
    private(set) var failed = false
    var supported: Bool { system.supported }
    var hasSupportedSelection: Bool { system.current == "MassiveXIcon001" || AppIconChoice.allCases.contains { $0.iconName == system.current } }
    func migrateRemovedSelection() async { if supported, !hasSupportedSelection { await select(.defaultChoice) } }
    init(system: any AppIconSwitching = SystemAppIconSwitcher()) { self.system = system; selected = .selected(system.current) }
    func refresh() { selected = .selected(system.current) }
    func select(_ choice: AppIconChoice) async {
        guard supported, !busy, choice.iconName != system.current else { return }
        busy = true; failed = false; defer { busy = false; refresh() }
        do { try await system.change(choice.iconName) } catch { failed = true }
    }
}
struct AppIconSettingsView: View {
    @Environment(AppLanguageSettings.self) private var language
    @Environment(\.scenePhase) private var phase
    @State private var settings = AppIconSettings()
    var body: some View {
        let _ = language.language
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L("Choose how Massive X appears on your Home Screen. iOS may show its own confirmation."))
                    .font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 16)], spacing: 20) {
                    ForEach(AppIconChoice.allCases) { choice in
                        Button { Task { await settings.select(choice) } } label: {
                            VStack(spacing: 10) {
                                Image(choice.previewName).resizable().scaledToFit().frame(width: 80, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 18))
                                    .overlay(alignment: .bottomTrailing) {
                                        if settings.hasSupportedSelection && choice == settings.selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).background(Theme.surface, in: Circle()) }
                                    }
                                Text(verbatim: choice.titleKey).font(.caption).foregroundStyle(.primary).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity, minHeight: 110)
                        }.buttonStyle(.plain).disabled(settings.busy || !settings.supported)
                            .accessibilityLabel(choice.titleKey).accessibilityAddTraits(settings.hasSupportedSelection && choice == settings.selected ? .isSelected : [])
                    }
                }
                if settings.busy { ProgressView() }
                if !settings.hasSupportedSelection { Button(L("Restore default icon")) { Task { await settings.select(.defaultChoice) } } }
                if !settings.supported { Text(L("Alternate icons are unavailable on this device.")) }
                if settings.failed { Text(L("The app icon could not be changed. Your current icon was kept. Try again.")) .foregroundStyle(Theme.warning) }
            }.padding(20)
        }.background(Theme.background).navigationTitle(L("App icon"))
            .task { await settings.migrateRemovedSelection(); settings.refresh() }
            .onChange(of: phase) { _, value in if value == .active { Task { await settings.migrateRemovedSelection(); settings.refresh() } } }
    }
}

/// Fixed public destinations only; no wallet/account data or affiliate parameters.
enum BuyMASDestinations {
    static let footer = "MAS purchases are handled by external exchanges. Availability and requirements vary by region."
    static let options = [
        EcosystemDestination(name: "Bitget", url: URL(string: "https://www.bitget.com/spot/MASUSDT")!),
        EcosystemDestination(name: "MEXC", url: URL(string: "https://www.mexc.com/exchange/MAS_USDT")!)
    ]
}
struct BuyMASView: View {
    @Environment(AppLanguageSettings.self) private var language
    @Environment(\.openURL) private var openURL
    @State private var openingFailed = false
    var body: some View {
        let _ = language.language
        List {
            Section {
                ForEach(BuyMASDestinations.options) { exchange in
                    Button {
                        openingFailed = false
                        openURL(exchange.url) { accepted in openingFailed = !accepted }
                    } label: {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: exchange.name).font(.headline).foregroundStyle(.primary)
                                Text("MAS/USDT · " + L("Spot trading")).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.square").foregroundStyle(Theme.accent)
                        }.frame(minHeight: 56).padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(.isLink)
                        .accessibilityHint(L("Opens an external website. No wallet connection or signing is performed."))
                }
            } footer: { Text(L(BuyMASDestinations.footer)) }
                .listRowBackground(Theme.surface)
            if openingFailed { Text(L("The website could not be opened. Try again.")).foregroundStyle(.secondary).listRowBackground(Theme.surface) }
        }.scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle(L("Buy MAS")).navigationBarTitleDisplayMode(.inline)
    }
}
