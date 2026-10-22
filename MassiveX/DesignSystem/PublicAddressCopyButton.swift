import SwiftUI

/// Public addresses only. Feedback is bound to the exact identity and never abbreviates the copied value.
@MainActor @Observable final class PublicAddressCopyState {
    private(set) var copiedAddress: String?
    private var generation = UUID()
    func copy(_ address: String, write: (String) -> Void) -> Bool {
        guard (try? MassaPublicAccount.validateAddress(address)) != nil else { return false }
        write(address); copiedAddress = address; generation = UUID()
        let token = generation
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, self.generation == token else { return }
            self.clear()
        }
        return true
    }
    func clear() { generation = UUID(); copiedAddress = nil }
}
struct PublicAddressCopyButton: View {
    @Environment(AppLanguageSettings.self) private var language
    let address: String
    var display: String? = nil
    @State private var feedback = PublicAddressCopyState()
    var body: some View {
        let _ = language.language
        Button {
            if feedback.copy(address, write: { UIPasteboard.general.string = $0 }), UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: L("Copied"))
            }
        } label: {
            ZStack(alignment: .leading) {
                // Reserve the address's layout while temporarily replacing its visible text.
                Text(display ?? address).fixedSize(horizontal: false, vertical: true)
                    .opacity(feedback.copiedAddress == address ? 0 : 1).accessibilityHidden(true)
                if feedback.copiedAddress == address { Text(L("Copied")).foregroundStyle(Theme.accent).accessibilityHidden(true) }
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.borderless).foregroundStyle(.primary)
            .disabled((try? MassaPublicAccount.validateAddress(address)) == nil)
            .accessibilityLabel(L("Copy address") + ": " + address)
            .accessibilityValue(feedback.copiedAddress == address ? L("Copied") : "")
            .onChange(of: address) { _, _ in feedback.clear() }
            .onDisappear { feedback.clear() }
    }
}
/// Both reviewed identities have identical layout. Only the expanded value is a copy target.
struct ReviewedAddressRow: View {
    let title: String
    let address: String
    let detail: String
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 12) {
                    Text(title)
                    Spacer(minLength: 8)
                    Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(L(expanded ? "Collapse" : "Expand"))
            if expanded {
                PublicAddressCopyButton(address: address).font(.subheadline.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
