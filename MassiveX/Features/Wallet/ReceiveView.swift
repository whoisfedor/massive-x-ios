import SwiftUI
import CoreImage.CIFilterBuiltins

struct ReceivePayload: Equatable {
    let address: String
    var qrData: Data { Data(address.utf8) }
    @MainActor func copyAddress(to board: UIPasteboard = .general) { board.string = address }
    init(wallet: ManagedWallet) throws {
        guard !wallet.isQuarantined, wallet.network == "Mainnet", wallet.storage == .current, !KnownUnsafeWallets.addresses.contains(wallet.address) else {
            throw MassaCoreError.invalidEncoding
        }
        try MassaPublicAccount.validateUserAddress(wallet.address)
        address = wallet.address
    }
}

struct ReceiveView: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    @Environment(WalletManager.self) private var wallets
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    private var payload: ReceivePayload? { wallets.selected.flatMap { try? ReceivePayload(wallet: $0) } }
    var body: some View {
        let _ = liveLanguage.language
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Label("Massa Mainnet", systemImage: "network").font(.headline).foregroundStyle(Theme.accent)
                    if let payload {
                        if let qr = Self.makeQR(payload.qrData) {
                            Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                                .frame(maxWidth: 240).padding(20).background(.white, in: RoundedRectangle(cornerRadius: 20))
                                .accessibilityLabel(L("QR code containing the selected public Massa address"))
                        } else { Text(L("QR generation unavailable. Use the address below.")) }
                        Text(payload.address).font(.body.monospaced()).textSelection(.enabled)
                            .multilineTextAlignment(.center).accessibilityIdentifier("receive.address")
                        Text(L("Receive only assets supported on Massa Mainnet. Verify the full address with the sender. The address itself does not encode a network."))
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button(copied ? L("Address copied") : L("Copy address")) {
                            payload.copyAddress(); copied = true
                        }.buttonStyle(PrimaryButtonStyle())
                        ShareLink(item: payload.address) { Label(L("Share address"), systemImage: "square.and.arrow.up") }
                        if wallets.selected?.kind == .watchOnly {
                            Text(L("Watch-only: this app does not possess the key or establish that you control this address."))
                                .font(.footnote).foregroundStyle(Theme.warning)
                        }
                    } else {
                        ContentUnavailableView(L("Receive unavailable"), systemImage: "lock",
                            description: Text(L("Select a Mainnet wallet. Archived or known public test accounts cannot be offered for funding.")))
                    }
                }.padding(24)
            }.background(Theme.background).navigationTitle(L("Receive MAS")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
                .onChange(of: wallets.selectedID) { _, _ in copied = false }
        }
    }
    static func makeQR(_ data: Data) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data; filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let rendered = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
        return UIImage(cgImage: rendered)
    }
}
