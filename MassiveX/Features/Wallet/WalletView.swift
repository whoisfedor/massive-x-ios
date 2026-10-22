import SwiftUI

struct WalletView: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    @Environment(HistoryPreferences.self) private var historyPreferences
    @Environment(WalletManager.self) private var wallets
    @Environment(FiatSettings.self) private var fiat
    @Environment(FiatPrices.self) private var prices
    @Environment(MainnetHistory.self) private var history
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Bindable var state: WalletState
    @Binding var selectedTab: AppTab
    @State private var selecting = false
    @State private var receiving = false
    @State private var sendInformation = false
    @State private var connectionDetails = false
    private var amount: MASAmount? { wallets.selectedID.flatMap { wallets.balances[$0] }.flatMap { try? MASAmount($0.finalBalance) } }
    private var primaryAmount: String {
        WalletAmountDisplay.summary(amount, showFiat: state.showsFiat, hidden: state.balanceHidden,
            quote: prices.quote(fiat.currency), currency: fiat.currency)
    }
    var body: some View {
        let _ = liveLanguage.language
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Spacer(minLength: 0)
                        Button { selecting = true } label: {
                            HStack(spacing: 7) {
                                if wallets.selected?.kind == .watchOnly { Image(systemName: "eye").font(.caption) }
                                Text(wallets.selected?.name ?? L("Add wallet")).font(.headline).lineLimit(1)
                                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                            }.foregroundStyle(Theme.accent).padding(.horizontal, 18).frame(minHeight: 44)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                        }.accessibilityLabel(L("Select wallet") + ", " + (wallets.selected?.name ?? L("No wallet selected")))
                        Spacer(minLength: 0)
                    }.padding(.bottom, 8)
                    if let selected = wallets.selected {
                        balance(selected)
                        HStack(spacing: 12) {
                            action("Send", icon: "arrow.up.right", disabled: selected.kind == .watchOnly) { sendInformation = true }
                                .accessibilityLabel(selected.kind == .watchOnly ? L("Send disabled for watch-only wallet") : L("Review a Mainnet transfer"))
                            action("Receive", icon: "arrow.down.left") { receiving = true }
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            Text(L("Assets")).font(.headline)
                            let assetLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 14))
                            assetLayout {
                                MassaCurrencySymbol().accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Massa").font(.body.weight(.semibold))
                                    Text("MAS").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(state.balanceHidden ? "••••" : amount.map { WalletAmountDisplay.mas($0) } ?? L("Unavailable"))
                                        .font(.body.weight(.semibold)).monospacedDigit()
                                    if state.showsFiat {
                                        CurrencyAmountText(parts: state.balanceHidden ? CurrencyDisplayParts(number: "••••") : WalletAmountDisplay.fiatParts(amount, quote: prices.quote(fiat.currency), currency: fiat.currency))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.surfaceCard().accessibilityElement(children: .combine)
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(L("Recent activity")).font(.headline)
                                HistoryRefreshButton(address: selected.address)
                                HistoryInfoButton(address: selected.address)
                                Spacer()
                                Button(L("See all")) { selectedTab = .activity }.font(.subheadline).frame(minHeight: 44)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                HistoryModePicker()
                                HistoryStatusView(address: selected.address)
                                ForEach(history.preview(selected.address, mode: historyPreferences.mode)) { operation in
                                    NavigationLink { OperationDetailView(operation: operation) } label: {
                                        OperationRow(operation: operation, address: selected.address, allowsAddressCopy: false)
                                    }.buttonStyle(.plain)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).surfaceCard()
                        }
                    } else {
                        ContentUnavailableView(L("Add a Mainnet wallet"), systemImage: "wallet.bifold",
                            description: Text(L("Create, import or watch an address to see its balance.")))
                        Button(L("Add wallet")) { selecting = true }.buttonStyle(PrimaryButtonStyle())
                    }
                }.padding(20)
            }.background(Theme.background)
            .blur(radius: selecting && !reduceTransparency ? 7 : 0)
            .allowsHitTesting(!selecting)
            .overlay { if selecting { Color.black.opacity(0.3).ignoresSafeArea().allowsHitTesting(false) } }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: selecting)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $selecting) {
                NavigationStack { WalletManagementView(pickerMode: true) }.preferredColorScheme(.dark).presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(CGFloat(min(540, 170 + 82 * max(1, wallets.activeWallets.count)))), .large]).presentationDragIndicator(.hidden).presentationCornerRadius(28).presentationBackground(Theme.walletSheet).presentationBackgroundInteraction(.disabled)
            }
            .sheet(isPresented: $receiving) { ReceiveView() }
            .sheet(isPresented: $sendInformation) { SendView() }
            .sheet(isPresented: $connectionDetails) { NavigationStack { WalletBalanceDetails() } }
            .refreshable {
                if let id = wallets.selectedID { await wallets.refreshBalance(id, force: true) }
                await prices.refresh(fiat.currency)
                if let address = wallets.selected?.address { await history.refresh(address, force: true) }
            }
        }
    }
    private func balance(_ selected: ManagedWallet) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(L("Total balance")).font(.subheadline).foregroundStyle(.secondary)
                Button { state.toggleBalance() } label: {
                    Image(systemName: state.balanceHidden ? "eye.slash" : "eye").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel(state.balanceHidden ? L("Show balance") : L("Hide balance"))
                Spacer()
                if wallets.loadingBalances.contains(selected.id) { ProgressView().controlSize(.small).accessibilityLabel(L("Refreshing balance")) }
            }
            Button { state.toggleUnit(); if state.showsFiat { Task { await prices.refresh(fiat.currency) } } } label: {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                layout {
                    Group {
                        if state.showsFiat && !state.balanceHidden {
                            CurrencyAmountText(parts: WalletAmountDisplay.fiatParts(amount, quote: prices.quote(fiat.currency), currency: fiat.currency), unitFont: .title3)
                        } else { Text(primaryAmount) }
                    }.font(.system(.largeTitle, design: .rounded, weight: .semibold)).tracking(-1).monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .easeInOut, value: state.balanceHidden)
                        .accessibilityIdentifier("wallet.balance")
                    if !state.showsFiat { Text("MAS").font(.title3).foregroundStyle(.secondary) }
                }.foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
                .accessibilityLabel(state.showsFiat ? L("Estimated value") + " " + fiat.currency : L("Total MAS balance"))
                .accessibilityValue(state.balanceHidden ? "Hidden" : primaryAmount)
                .accessibilityHint(L("Double tap to switch MAS and fiat display"))
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5)) : AnyLayout(HStackLayout(spacing: 5))) {
                Button { connectionDetails = true } label: {
                    HStack(spacing: 5) {
                        MainnetConnectionDot(lastVerified: wallets.lastUpdated[selected.id], failed: wallets.balanceErrors[selected.id] != nil, checking: wallets.loadingBalances.contains(selected.id))
                        Text(L("Mainnet"))
                    }.frame(minHeight: 44)
                }.buttonStyle(.plain)
                PublicAddressCopyButton(address: selected.address, display: selected.shortAddress)
                    .id(selected.id)
                if state.showsFiat { Text(L("· Estimate")) }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
    private func action(_ title: String, icon: String, disabled: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(L(title), systemImage: icon).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 18)
                .foregroundStyle(disabled ? Color.secondary : Theme.accent)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
        }.disabled(disabled)
    }
}

private struct WalletBalanceDetails: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    @Environment(WalletManager.self) private var wallets
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let _ = liveLanguage.language
        List {
            if let selected = wallets.selected {
                Section(selected.name) {
                    Text(L("Massa Mainnet · Final-state balance")).font(.headline)
                    if let date = wallets.lastUpdated[selected.id] { LabeledContent(L("Last successful read"), value: localizedDate(date)) }
                    if let error = wallets.balanceErrors[selected.id] { Text(L(error)).foregroundStyle(Theme.warning) }
                    Button(L("Refresh balance")) { Task { await wallets.refreshBalance(selected.id, force: true) } }
                }.listRowBackground(Theme.surface)
            }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle(L("Balance details"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
    }
}
