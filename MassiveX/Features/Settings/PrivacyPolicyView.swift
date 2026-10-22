import SwiftUI

struct PrivacyPolicySettingsRow: View {
    @Environment(AppLanguageSettings.self) private var language
    @Environment(\.openURL) private var openURL
    @State private var failed = false
    var body: some View {
        let _ = language.language
        Button {
            guard let url = PrivacyPolicyConfiguration.publishedURL else { failed = true; return }
            openURL(url) { accepted in failed = !accepted }
        } label: { Label(L("Privacy Policy"), systemImage: "hand.raised") }
            .accessibilityIdentifier("settings.privacyPolicy")
            .alert(L("The website could not be opened. Try again."), isPresented: $failed) { Button(L("Done"), role: .cancel) {} }
    }
}
struct PrivacyPolicyView: View {
    var body: some View { PrivacyPolicySettingsRow() }
}
