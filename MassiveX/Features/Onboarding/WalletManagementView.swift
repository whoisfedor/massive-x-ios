import SwiftUI

private struct WalletAddedActionKey: EnvironmentKey { static var defaultValue: () -> Void { {} } }
extension EnvironmentValues {
    var walletAdded: () -> Void { get { self[WalletAddedActionKey.self] } set { self[WalletAddedActionKey.self] = newValue } }
}
struct WalletManagementView: View {
    @Environment(\.walletAdded) private var walletAdded
    @Environment(AppLanguageSettings.self) private var liveLanguage
    var pickerMode = false
    @Environment(FiatSettings.self) private var fiat
    @Environment(FiatPrices.self) private var prices
    @Environment(WalletState.self) private var privacy
    @Environment(WalletManager.self) private var wallets
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var renaming: ManagedWallet?
    @State private var newName = ""
    var body: some View {
        let _ = liveLanguage.language
        List {
            Section {
                ForEach(wallets.activeWallets) { wallet in
                    Button { wallets.select(wallet.id); if pickerMode { dismiss() } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: wallet.kind == .owned ? "wallet.bifold" : "eye")
                                .foregroundStyle(Theme.accent).frame(width: 44, height: 44)
                                .background(Theme.accent.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(wallet.name).font(.headline)
                                Text(wallet.shortAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if wallet.kind == .watchOnly { Text(L("Watch-only")).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let balance = wallets.balances[wallet.id] {
                                if privacy.showsFiat && !privacy.balanceHidden {
                                    CurrencyAmountText(parts: WalletAmountDisplay.fiatParts(try? MASAmount(balance.finalBalance), quote: prices.quote(fiat.currency), currency: fiat.currency)).font(.caption)
                                } else {
                                    Text(WalletAmountDisplay.summary(try? MASAmount(balance.finalBalance), showFiat: false, hidden: privacy.balanceHidden, quote: nil, currency: fiat.currency)).font(.caption).monospacedDigit()
                                }
                            }
                            if wallets.selectedID == wallet.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                        }.foregroundStyle(.primary).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityLabel("\(wallet.name), \(wallet.kind == .owned ? L("Owned") : L("Watch-only")), \(wallets.selectedID == wallet.id ? L("Selected") : L("Not selected"))")
                    .contextMenu { Button(L("Rename")) { newName = wallet.name; renaming = wallet } }
                }
                if wallets.activeWallets.isEmpty { Text(L("No wallets added")).foregroundStyle(.secondary) }
                if !pickerMode { Button { adding = true } label: { Label(L("Add wallet"), systemImage: "plus.circle") } }
            }.listRowBackground(Theme.surface)
            if !pickerMode, let selected = wallets.selected {
                Section(selected.name) {
                    if let backup = wallets.backup {
                        NavigationLink { WalletOnboardingView().environment(backup) } label: { Label(L("Backup"), systemImage: "key") }
                    } else {
                        Label(L("Watch-only · No private key"), systemImage: "eye")
                    }
                    Button(L("Rename wallet")) { newName = selected.name; renaming = selected }
                    Text(L(SendDisclosure.text))
                        .font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(Theme.surface)
            }
        }
        .contentMargins(.top, 8, for: .scrollContent)
        .scrollContentBackground(.hidden).background(pickerMode ? Theme.walletSheet : Theme.background)
        .navigationTitle(L("Wallets")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "xmark").accessibilityLabel(L("Close wallets")) } } }
        .safeAreaInset(edge: .bottom) {
            if pickerMode {
                Button { adding = true } label: { Label(L("Add wallet"), systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle()).padding(16).background(Theme.walletSheet)
            }
        }
        .sheet(isPresented: $adding) { NavigationStack { AddWalletView { adding = false; if pickerMode { dismiss() }; walletAdded() } }.presentationDragIndicator(.visible) }
        .alert(L("Rename wallet"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Wallet name"), text: $newName)
            Button(L("Save")) { if let renaming { wallets.rename(renaming.id, name: newName) }; renaming = nil }
            Button(L("Cancel"), role: .cancel) { renaming = nil }
        }
    }
}

struct AddWalletView: View {
    var onAdded: () -> Void = {}
    @Environment(SendCoordinator.self) private var send
    @Environment(AppLanguageSettings.self) private var liveLanguage
    enum Mode { case choices, newWallet, privateKey, watchOnly, yaml }
    @Environment(WalletManager.self) private var wallets
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.isSceneCaptured) private var captured
    @State private var mode = Mode.choices
    @State private var name = ""
    @State private var key = ""
    @State private var address = ""
    private enum Field: Hashable { case name, key, address }
    @State private var focused: Field?
    @State private var nameError = false
    init(onAdded: @escaping () -> Void = {}, initialMode: Mode = .choices) {
        self.onAdded = onAdded; _mode = State(initialValue: initialMode)
    }
    private var privateScene: Bool { phase == .active && !captured }
    var body: some View {
        let _ = liveLanguage.language
        List {
            Group {
                if mode != .privateKey { Section { Text(L(SendDisclosure.text)).font(.footnote).foregroundStyle(.secondary) } }
                if mode == .choices {
                    Section {
                        menuRow("New wallet", icon: "plus.circle") { mode = .newWallet }
                        menuRow("Import private key", icon: "key") { mode = .privateKey }
                        menuRow("Import Massa YAML", icon: "doc") { mode = .yaml }
                        menuRow("Watch-only wallet", icon: "eye") { mode = .watchOnly }
                    }
                } else if mode == .yaml {
                    YAMLWalletImportForm(onAdded: onAdded)
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Wallet name (optional)")).font(.caption).foregroundStyle(.secondary)
                            WalletInputField(title: L("Wallet name (optional)"), text: $name, isFocused: focus(.name), role: .name, identifier: "wallet.name").frame(minHeight: 44)
                        }.padding(.vertical, 8)
                        if nameError { Text(L("Enter a wallet name of 1–40 characters.")).foregroundStyle(Theme.warning) }
                        if mode == .privateKey {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L("Massa S1 private key")).font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 12) {
                                    WalletInputField(title: L("Massa S1 private key"), text: $key, isFocused: focus(.key), role: .privateKey, identifier: "wallet.private-key", eraseContent: !privateScene)
                                        .frame(minHeight: 44).privacySensitive()
                                    CompactPasteButton(label: L("Paste private key")) { values in
                                        guard privateScene else { return }; key = (values.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                }
                            }.padding(.vertical, 8)
                            if !key.isEmpty && !WalletImportPresentation.validKey(key) { Text(L("Invalid Massa S1 private key. Check its format and checksum. No input was logged.")).font(.footnote).foregroundStyle(.secondary) }
                            Text(L("Validated locally. No recovery phrases or mnemonic derivation are supported.")).font(.footnote).foregroundStyle(.secondary)
                        } else if mode == .watchOnly {
                            HStack {
                                WalletInputField(title: L("Massa user address (AU)"), text: $address, isFocused: focus(.address), role: .address, identifier: "wallet.address").frame(minHeight: 44)
                                CompactPasteButton(label: L("Paste address")) { values in guard privateScene else { return }; address = (values.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                            }
                            if !address.isEmpty && (try? MassaPublicAccount.validateUserAddress(address)) == nil { Text(L("Enter a valid Massa user address (AU)." )).font(.footnote).foregroundStyle(.secondary) }
                            Text(L("Read-only tracking. No key, signing or backup capability. Addresses do not encode a network; all queries stay on Mainnet."))
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text(L("Creates a native Massa keypair. Save its private-key backup afterward. No recovery phrase is generated."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button(mode == .newWallet ? L("Create wallet") : L("Add wallet")) { add() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(!privateScene || !validName || mode == .privateKey && !WalletImportPresentation.validKey(key) || mode == .watchOnly && (try? MassaPublicAccount.validateUserAddress(address)) == nil)
                    }
                }
                if mode != .yaml && wallets.isBusy { Section { ProgressView(L("Authenticating…")) } }
                if mode != .yaml, let message = wallets.message { Section { Text(L(message)).font(.subheadline) } }
            }.listRowBackground(Theme.surface)
        }
        .buttonStyle(.borderless).disabled(wallets.isBusy)
        .scrollContentBackground(.hidden).background(Theme.background).scrollDismissesKeyboard(.interactively)
        .navigationTitle(mode == .choices ? L("Add wallet") : mode == .newWallet ? L("New wallet") : mode == .privateKey ? L("Import private key") : mode == .yaml ? L("Import Massa YAML") : L("Watch-only wallet"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(mode == .choices ? L("Cancel") : L("Back")) {
                    key = ""; focused = nil
                    if mode == .choices { dismiss() } else { mode = .choices }
                }
            }
        }
        .alert(L("Wallet already added"), isPresented: Binding(get: { wallets.duplicateID != nil }, set: { if !$0 { wallets.dismissDuplicate() } })) {
            Button(L("Select existing wallet")) { if let id = wallets.duplicateID { wallets.select(id); onAdded(); dismiss() } }
            Button(L("Cancel"), role: .cancel) { wallets.dismissDuplicate() }
        } message: { Text(L("This address already exists. Its key and metadata were not changed.")) }
        .onChange(of: phase) { _, _ in updatePrivacy() }
        .onChange(of: captured) { _, _ in updatePrivacy() }
        .onDisappear { key = ""; wallets.cancelCreation() }
    }
    private func focus(_ field: Field) -> Binding<Bool> {
        Binding(get: { focused == field }, set: { value in if value { focused = field } else if focused == field { focused = nil } })
    }
    private var validName: Bool { WalletNamePresentation.validOptional(name) }
    private func menuRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(L(title), systemImage: icon).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle()) }
            .buttonStyle(.plain)
    }
    private func updatePrivacy() {
        if !privateScene { key = "" }
        if phase == .background || captured { focused = nil }
        wallets.creationPrivacy(active: phase == .active, captured: captured, background: phase == .background)
    }
    private func add() {
        focused = nil
        guard privateScene else { return }
        guard validName else { nameError = true; return }; nameError = false
        guard mode != .privateKey || WalletImportPresentation.validKey(key) else { return }
        if mode == .watchOnly {
            if wallets.addWatchOnly(address: address, name: WalletNamePresentation.importName(name)) { onAdded(); dismiss() }
        } else {
            let input: String? = mode == .privateKey ? key : nil
            key = ""
            Task { if await wallets.addOwned(privateKey: input, name: WalletNamePresentation.importName(name), active: phase == .active, captured: captured, creationJournalID: send.journalIdentity) { onAdded(); dismiss() } }
        }
    }
}

enum WalletNamePresentation {
    static func importName(_ name: String) -> String { let value = name.trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? "Wallet" : value }
    static func validOptional(_ name: String) -> Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || valid(name) }
    static func valid(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 40 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// UI enablement only; the existing authenticated import path validates again.
enum WalletImportPresentation {
    static func validKey(_ input: String) -> Bool { (try? MassaCodec.decode(input, prefix: "S")) != nil }
}
