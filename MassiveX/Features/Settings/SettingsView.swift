import SwiftUI

enum WalletLogoutText {
    static let action = "Log out of wallet"
    static let confirmationTitle = "Log out"
    static let confirmationAction = "Log out and remove local keys"
    static let incompleteTitle = "Wallet logout incomplete"
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case dark = "Dark", light = "Light", system = "System"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .dark: .dark; case .light: .light; case .system: nil }
    }
}

struct SettingsView: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    @Binding var selectedTab: AppTab
    @Environment(FiatSettings.self) private var fiat
    @Environment(AppLanguageSettings.self) private var languages
    @Environment(WalletManager.self) private var wallets
    @State private var confirmingRemoval = false
    @Binding var navigation: SettingsNavigationState
    @AppStorage("appearance") private var appearance = AppAppearance.dark.rawValue
    @State private var themes = ThemeSettings.shared
    var body: some View {
        let _ = liveLanguage.language
        NavigationStack(path: $navigation.path) {
            List {
                Group {
                    Section {
                        HStack(spacing: 14) {
                            Image(systemName: "wallet.bifold").font(.title2).foregroundStyle(Theme.accent)
                                .frame(width: 48, height: 48).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Massive X").font(.headline)
                                Text(L("Version") + " " + AppVersionLabel.current).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)

                    }.listRowBackground(Theme.surface)
                    Section(L("Preferences")) {
                        NavigationLink(value: SettingsDestination.wallets) { Label(L("Wallets and Backup"), systemImage: "wallet.bifold") }
                        NavigationLink(value: SettingsDestination.fiat) { LabeledContent { Text(fiat.currency) } label: { Label(L("Currency"), systemImage: "dollarsign.circle") } }
                        Menu {
                            ForEach(AccentPalette.allCases) { palette in
                                Button { themes.select(palette) } label: {
                                    HStack { Text(verbatim: palette.title); if themes.palette == palette { Image(systemName: "checkmark") } }
                                }
                            }
                        } label: { SettingsSelectionLabel(title: L("Accent Color"), icon: "paintpalette", value: themes.palette.title) }
                            .tint(Theme.accent).accessibilityLabel(L("Accent Color")).accessibilityValue(themes.palette.title)
                        NavigationLink(value: SettingsDestination.language) {
                            LabeledContent { Text(verbatim: languages.language.name).foregroundStyle(.secondary) } label: { Label(L("Language"), systemImage: "globe") }
                        }.accessibilityIdentifier("settings.language")
                        NavigationLink(value: SettingsDestination.notifications) { Label(L("Balance notifications"), systemImage: "bell.badge") }
                        Menu {
                            ForEach(AppAppearance.allCases) { option in
                                Button { appearance = option.rawValue } label: {
                                    HStack { Text(L(option.rawValue)); if appearance == option.rawValue { Image(systemName: "checkmark") } }
                                }
                            }
                        } label: { SettingsSelectionLabel(title: L("Appearance"), icon: "circle.lefthalf.filled", value: L(appearance)) }
                            .tint(Theme.accent).accessibilityLabel(L("Appearance")).accessibilityValue(L(appearance))
                    }
                    Section(L("App")) {
                        NavigationLink(value: SettingsDestination.buyMAS) { Label(L("Buy MAS"), systemImage: "cart") }
                        NavigationLink(value: SettingsDestination.ecosystem) { Label(L("Massa Ecosystem"), systemImage: "square.grid.2x2") }
                        NavigationLink(value: SettingsDestination.network) { Label(L("Mainnet connection"), systemImage: "network") }
                        NavigationLink(value: SettingsDestination.about) { Label(L("About & Roadmap"), systemImage: "info.circle") }
                        PrivacyPolicySettingsRow()
                        NavigationLink(value: SettingsDestination.icon) { Label(L("App icon"), systemImage: "app.badge") }
                        LabeledContent(L("Version"), value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—") + ")")
                        LabeledContent(L("Environment"), value: L("Mainnet only"))
                    }
                    Section {
                        Button(role: .destructive) { if wallets.beginRemovalReview() != nil { confirmingRemoval = true } } label: { Label(L(WalletLogoutText.action), systemImage: "trash") }
                            .disabled(wallets.selected == nil || wallets.isBusy)
                    }
                    Section { Text(L(SendDisclosure.text))
                        .font(.footnote).foregroundStyle(.secondary) }

                }.listRowBackground(Theme.surface)
            }.listRowSpacing(2).scrollContentBackground(.hidden).background(Theme.background).navigationTitle(L("Settings"))
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .wallets: WalletManagementView()
                case .fiat: FiatCurrencyView()
                case .language: LanguageSettingsView()
                case .notifications: BalanceNotificationSettingsView()
                case .ecosystem: MassaEcosystemView()
                case .buyMAS: BuyMASView()
                case .network: MainnetView()
                case .about: AboutView()
                case .privacy: PrivacyPolicyView()
                case .icon: AppIconSettingsView()
                }
            }
            .onChange(of: navigation.generation) { _, _ in
                confirmingRemoval = false; wallets.cancelRemovalReview()
            }
            .sheet(isPresented: $confirmingRemoval, onDismiss: { wallets.cancelRemovalReview() }) {
                WalletLogoutView { selectedTab = .wallet }
            }
        }
    }

}

enum SettingsDestination: Hashable { case wallets, fiat, language, notifications, ecosystem, network, about, privacy, icon, buyMAS }
struct SettingsNavigationState {
    var path: [SettingsDestination] = []
    private(set) var generation = 0
    mutating func tabChanged(settingsSelected: Bool) { path = []; generation += 1 }
}

struct AboutView: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    var body: some View {
        let _ = liveLanguage.language
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("About Massive X")).font(.title2.bold())
                    Text(L("Manage MAS, explore activity and approve payments from your iPhone. Your private keys stay protected on your device.")).font(.subheadline).foregroundStyle(.secondary)
                    Link("massive-x.com ↗", destination: URL(string: "https://massive-x.com/")!)
                    DisclosureGroup(L("About this app")) { Text(L(ProductRoadmap.overview)).font(.footnote) }
                    PrivacyPolicySettingsRow()
                }.surfaceCard()
                Text(L("Roadmap")).font(.title2.bold())
                VStack(spacing: 0) {
                    ForEach(ProductRoadmap.shipped, id: \.title) { item in milestone(item, shipped: true) }
                    ForEach(ProductRoadmap.phases, id: \.title) { item in milestone(item, shipped: false) }
                }
                Text(L("Plans may change; no dates guaranteed.")).font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: 650).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle(L("About & Roadmap")).navigationBarTitleDisplayMode(.inline)
    }
    private func milestone(_ item: ProductRoadmap.Phase, shipped: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(shipped ? Color.blue : Theme.background).frame(width: 24, height: 24)
                    Circle().stroke(shipped ? Color.blue : Color.secondary, lineWidth: 2).frame(width: 24, height: 24)
                    if shipped { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) }
                }.padding(.top, 18)
                Rectangle().fill(Color.secondary.opacity(0.22)).frame(width: 2).frame(maxHeight: .infinity)
            }.frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(L(shipped ? "Shipped" : "Planned / Subject to development")).font(.caption.weight(.semibold)).foregroundStyle(shipped ? Color.blue : Color.secondary)
                Text(L(item.title)).font(.headline)
                DisclosureGroup(L("Details")) { Text(L(item.detail)).font(.subheadline).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).surfaceCard().padding(.bottom, 16)
        }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .contain)
    }
}
enum ProductRoadmap {
    static let overview = "Massive X is a self-custodial wallet built for the Massa blockchain. Create or import accounts, track balances and activity, and send and receive MAS. Transfers are initiated and approved by you. Your private keys are protected on your device, with backup or export only when you explicitly request it. Network information comes from Massa and other external data providers."
    struct Phase { let title: String; let detail: String }
    static let shipped = [
        Phase(title: "Owned and watch-only wallets", detail: "Create or import accounts, switch wallets and track watch-only addresses."),
        Phase(title: "Protected keys and backup", detail: "On-device protected signing and deliberately authenticated backup access."),
        Phase(title: "Mainnet MAS payments", detail: "Manually reviewed MAS Send, Receive addresses and genuine operation status."),
        Phase(title: "Balances, activity and alerts", detail: "Mainnet balances, transaction history and optional balance-change alerts. iOS background delivery is not guaranteed."),
        Phase(title: "Currency estimates and recent recipients", detail: "Currency estimates and a wallet-scoped list of confirmed outgoing recipients. A full address book and chart are still planned."),
        Phase(title: "Make it yours", detail: "Six languages, accent colors, app icons and external Massa ecosystem links.")
    ]
    static let phases = [
        Phase(title: "Next", detail: "MAS market-price chart, payment-request QR, full address book and further transaction exploration improvements."),
        Phase(title: "Planned", detail: "Smart Contracts & NFT Support: permission previews for smart-contract interactions; NFT discovery, display, receive, send and history; deeper Massa ecosystem connectivity."),
        Phase(title: "Longer-term / Exploratory", detail: "Encrypted wallet chat with deliberate MAS and NFT sending; verified contacts; scam and spam protection; optional DApp connections; swaps and bridges where secure integrations exist; hardware wallet compatibility; additional backup options.")
    ]
}

enum AppVersionLabel {
    static var current: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String ?? "—") + " (" + (info["CFBundleVersion"] as? String ?? "—") + ")"
    }
}

/// A real SwiftUI value label avoids the native Picker's cached blue selected-value rendering.
private struct SettingsSelectionLabel: View {
    let title: String
    let icon: String
    let value: String
    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: icon).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(verbatim: value).foregroundStyle(Theme.accent).multilineTextAlignment(.trailing)
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Theme.accent)
        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
    }
}
