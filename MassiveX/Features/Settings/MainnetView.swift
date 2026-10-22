import SwiftUI

struct MainnetView: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    @State private var state = MainnetState()
    var body: some View {
        let _ = liveLanguage.language
        List {
            Section(L("Only network")) {
                LabeledContent(L("Network"), value: "Massa Mainnet")
                Text(MassaEnvironment.mainnet.endpoint.absoluteString).font(.caption.monospaced())
                Text(L("No alternate endpoint, network or sample-data fallback. Sending is disabled.")).font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Theme.surface)
            Section(L("Connection")) {
                switch state.phase {
                case .idle: Text(L("Not checked"))
                case .loading: ProgressView(L("Checking Mainnet…"))
                case .connected(let status):
                    LabeledContent(L("Node version"), value: status.version)
                    LabeledContent(L("Chain ID"), value: String(status.chainID))
                case .unavailable(let message): Text(L(message)).foregroundStyle(Theme.warning)
                }
                Button(L("Check connection")) { Task { await state.refresh() } }
            }.listRowBackground(Theme.surface)
        }.scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Mainnet").navigationBarTitleDisplayMode(.inline)
    }
}
