import SwiftUI
import UIKit

/// Selected owned-wallet backup only. Creation/import and watch-only management live separately.
struct WalletOnboardingView: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    var unsafeArchive = false
    @Environment(WalletOnboarding.self) private var wallet
    @Environment(\.scenePhase) private var phase
    @Environment(\.isSceneCaptured) private var captured
    @State private var confirmCopy = false
    private var privateScene: Bool { phase == .active && !captured }
    var body: some View {
        let _ = liveLanguage.language
        List {
            Group {
                if unsafeArchive {
                    Section { Label(L("Unsafe archived preview key · Never fund"), systemImage: "exclamationmark.shield") }
                        .foregroundStyle(Theme.warning)
                }
                Section {
                    Label(wallet.record?.backupAcknowledged == true ? L("I saved my backup") : L("Backup not confirmed"),
                          systemImage: wallet.record?.backupAcknowledged == true ? "checkmark.shield" : "shield")
                    Text(L("Anyone with your private key controls the wallet. Losing the only copy can permanently remove access."))
                        .font(.subheadline)
                }
                if privateScene {
                    Section {
                        Button(L("Show private key")) { begin { await wallet.reveal(risksAcknowledged: true) } }
                        if let key = wallet.revealedKey {
                            Text(key).font(.body.monospaced()).privacySensitive()
                                .accessibilityLabel(L("Sensitive private key")).accessibilityValue(Text(L("Hidden from accessibility output")))
                            Button(L("Hide")) { wallet.conceal() }
                        }
                        Button(L("Copy private key")) { confirmCopy = true }
                        if wallet.clipboardActive { Button(L("Clear copied key")) { wallet.clearClipboard() } }
                    }
                    if wallet.record?.backupAcknowledged != true {
                        Section {
                            Button(L("I saved my backup")) { wallet.acknowledgeBackup() }
                            Text(L("This is your acknowledgement, not proof that an offline backup exists."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                }
                Section {
                    Text(L("The key stays visible until you tap Hide or leave this screen. Inactivity also masks it. iOS cannot reliably prevent screenshots or external cameras; reveal only in private."))
                    DisclosureGroup("Storage and recovery limits") {
                        Text(L("Keys are protected by device-only Keychain with Face ID, Touch ID or device passcode. This is not Secure Enclave Ed25519 signing. Device replacement requires a private backup. Reinstall can leave a key without public preferences; it is not a backup or erasure method. Removing the passcode invalidates this storage class. Biometric changes do not revoke ownership."))
                    }
                }.font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Theme.surface)
        }
        .buttonStyle(.borderless).disabled(wallet.isBusy)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden).background(Theme.background)
        .safeAreaInset(edge: .bottom) {
            if wallet.isBusy || wallet.message != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if wallet.isBusy { ProgressView(L("Authenticating…")) }
                    if let message = wallet.message { Text(L(message)).font(.subheadline) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding().background(Theme.surface)
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle(unsafeArchive ? L("Archived backup") : L("Backup")).navigationBarTitleDisplayMode(.inline)
        .transaction { $0.animation = nil }
        .confirmationDialog(L("Copy private key?"), isPresented: $confirmCopy, titleVisibility: .visible) {
            Button(L("Authenticate and copy"), role: .destructive) {
                begin { await wallet.copyForBackup(risksAcknowledged: true, clipboardConsent: true) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Copy only to this iPhone’s clipboard with a 5-minute system expiration. Leaving Backup or switching apps does not clear it. Other apps may read or keep pasted content; expiration cannot revoke those copies. Never paste a key into chat. Copying is not an offline backup."))
        }
        .onAppear { updatePrivacy() }
        .onChange(of: phase) { _, _ in updatePrivacy() }
        .onChange(of: captured) { _, _ in updatePrivacy() }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in wallet.refreshClipboardStatus() }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.removedNotification)) { _ in wallet.refreshClipboardStatus() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            wallet.screenshotDetected()
        }
        .onDisappear { wallet.close() }
    }
    private func begin(_ operation: @escaping @MainActor () async -> Void) {
        updatePrivacy()
        Task { await operation() }
    }
    private func updatePrivacy() {
        if !privateScene { confirmCopy = false }
        wallet.updatePrivacy(active: phase == .active, captured: captured, background: phase == .background)
    }
}
