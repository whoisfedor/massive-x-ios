import SwiftUI

/// Self-attestation is not backup proof. Fresh OS authorization and exact selected identity remain mandatory.
struct WalletLogoutView: View {
    @Environment(WalletManager.self) private var wallets
    @Environment(AppLanguageSettings.self) private var language
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var acknowledged = false
    @State private var backup: WalletOnboarding?
    let completed: () -> Void
    var body: some View {
        let _ = language.language
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("Log out")).font(.title.bold())
                    if let plan = wallets.removalPlan, let wallet = plan.wallets.first {
                        HStack {
                            Text(wallet.name).font(.headline).lineLimit(1)
                            Spacer()
                            Text(wallet.shortAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(L(wallet.kind == .owned ? "This wallet’s local keys will be removed from this device." : "Only this watch-only wallet will be removed. No private key is stored.")).foregroundStyle(.secondary)
                        Button { acknowledged.toggle() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: acknowledged ? "checkmark.square.fill" : "square").foregroundStyle(Theme.accent)
                                Text(L(wallet.kind == .owned ? "I have a backup of this wallet's private key." : "Remove this watch-only wallet from this device.")).foregroundStyle(.primary)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(wallets.removalBusy).accessibilityAddTraits(acknowledged ? .isSelected : [])
                        HStack(spacing: 20) {
                            if let backup {
                                NavigationLink(L("Back up private key")) { WalletOnboardingView().environment(backup) }
                            }

                        }.font(.subheadline).foregroundStyle(Theme.accent).frame(minHeight: 44).disabled(wallets.removalBusy)
                        Button(L("Log out"), role: .destructive) {
                            Task { if await wallets.removeCurrentWallets(plan, acknowledged: acknowledged) { completed(); dismiss() } }
                        }.buttonStyle(PrimaryButtonStyle())
                            .disabled(!acknowledged || !wallets.canAuthorizeRemoval(plan) || wallets.removalBusy)
                            .accessibilityIdentifier("logout.authenticate")
                        Text(L(wallet.kind == .owned ? "Funds stay on chain. Restoring access requires your own valid private-key backup." : "Funds stay on chain. You can add this public address again.")).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button(L("Review wallet list again")) { acknowledged = false; wallets.beginRemovalReview(); prepareBackup() }
                    }
                    if wallets.removalBusy { ProgressView(L("Authenticating…")) }
                    if let failure = wallets.removalFailure { Text(failure.message).font(.footnote).foregroundStyle(.secondary) }
                }.padding(20)
            }.background(Theme.walletSheet).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button { wallets.cancelRemovalReview(); dismiss() } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel(L("Close"))
                } }
        }
        .preferredColorScheme(.dark).presentationDetents([.height(470), .large]).presentationDragIndicator(.hidden).presentationBackground(Theme.walletSheet)
        .onAppear { wallets.removalPrivacy(active: phase == .active, captured: UIScreen.main.isCaptured); prepareBackup() }
        .onChange(of: wallets.removalPlan?.id) { _, _ in acknowledged = false; backup?.close(); prepareBackup() }
        .onDisappear { acknowledged = false; backup?.close(); wallets.cancelRemovalReview() }
    }
    private func prepareBackup() {
        guard let plan = wallets.removalPlan, let wallet = plan.owned.first else { backup = nil; return }
        backup = wallets.removalBackup(plan, walletID: wallet.id)
    }
}
