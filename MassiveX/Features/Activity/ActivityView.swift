import SwiftUI

struct ActivityView: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    @Environment(HistoryPreferences.self) private var preferences
    @Environment(WalletManager.self) private var wallets
    @Environment(MainnetHistory.self) private var history
    var body: some View {
        let _ = liveLanguage.language
        NavigationStack {
            List {
                Section { HistoryModePicker() }.listRowBackground(Theme.background)
                if let address = wallets.selected?.address {
                    Section {
                        HistoryStatusView(address: address)
                        ForEach(history.filtered(address, mode: preferences.mode)) { operation in
                            NavigationLink { OperationDetailView(operation: operation) } label: {
                                OperationRow(operation: operation, address: address)
                            }
                        }
                        if history.cursors[address] != nil {
                            Button(L("Load more")) { Task { await history.refresh(address, more: true) } }.disabled(history.loading.contains(address))
                        }
                    }.listRowBackground(Theme.surface)
                } else {
                    ContentUnavailableView(L("Select a wallet"), systemImage: "wallet.bifold", description: Text(L("Add or select a wallet to view its Mainnet activity.")))
                }
            }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle(L("Activity"))
                .toolbar { ToolbarItemGroup(placement: .topBarTrailing) { if let address = wallets.selected?.address { HistoryInfoButton(address: address); HistoryRefreshButton(address: address) } } }
                .refreshable { if let address = wallets.selected?.address { await history.refresh(address, force: true) } }
                .task(id: wallets.selected?.address) { let address = wallets.selected?.address; history.activate(address); if let address { await history.refresh(address) } }
        }
    }
}

struct HistoryStatusView: View {
    @Environment(HistoryPreferences.self) private var preferences
    @Environment(AppLanguageSettings.self) private var liveLanguage
    let address: String
    @Environment(MainnetHistory.self) private var history
    var body: some View {
        let _ = liveLanguage.language
        switch HistoryListPresentation.status(history.presentationState(address, mode: preferences.mode)) {
        case .loading: ProgressView().accessibilityLabel(L("Loading activity…"))
        case .empty: Text(L("No operations found")).foregroundStyle(.secondary)
        case .quiet: EmptyView()
        }
    }
}
struct OperationRow: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    let operation: MainnetOperation
    let address: String
    var allowsAddressCopy = true
    @Environment(WalletState.self) private var privacy
    var body: some View {
        let _ = liveLanguage.language
        HStack(spacing: 12) {
            Image(systemName: operation.direction(for: address) == .incoming ? "arrow.down.left" : "arrow.up.right")
                .foregroundStyle(Theme.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(operation.title(for: address)).font(.subheadline.weight(.semibold))
                if HistoryListPresentation.showStatus(operation) {
                    Text(HistoryListPresentation.statusLabel(operation)).font(.caption).foregroundStyle(operation.executionSucceeded == false ? Theme.warning : Color.secondary)
                }
                if let other = operation.shortCounterparty(for: address) {
                    if allowsAddressCopy {
                        PublicAddressCopyButton(address: operation.sender == address ? (operation.recipient ?? "") : operation.sender, display: other)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    } else {
                        // Home's recent row belongs entirely to its operation-details NavigationLink.
                        Text(other).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                CurrencyAmountText(parts: privacy.balanceHidden ? CurrencyDisplayParts(number: "••••") : operation.amount.map { .formatted(number: $0.text, currency: "MAS") } ?? CurrencyDisplayParts(number: "—")).font(.subheadline).monospacedDigit()
                Text(HistoryListPresentation.timestamp(operation.date, locale: liveLanguage.language.locale, timeZone: .current))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }.padding(.vertical, 6).accessibilityElement(children: .contain)
    }
}
struct OperationDetailView: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    let operation: MainnetOperation
    @Environment(WalletState.self) private var privacy
    var body: some View {
        let _ = liveLanguage.language
        List {
            Section(L("Operation")) {
                Text(operation.operationID ?? operation.id).font(.caption.monospaced()).textSelection(.enabled)
                if let index = operation.transferIndex { LabeledContent(L("Transfer index"), value: String(index)) }
                if operation.operationID == nil { Text(L("Indexer record; no chain operation ID supplied.")).font(.caption) }
                LabeledContent(L("Status"), value: operation.statusLabel)
                if let date = operation.date { LabeledContent(L("Block time"), value: localizedDate(date)) }
                LabeledContent(L("Amount")) { CurrencyAmountText(parts: privacy.balanceHidden ? CurrencyDisplayParts(number: "••••") : operation.amount.map { .formatted(number: $0.text, currency: "MAS") } ?? CurrencyDisplayParts(number: "—")) }
                if let fee = operation.fee { LabeledContent(L("Fee")) { CurrencyAmountText(parts: privacy.balanceHidden ? CurrencyDisplayParts(number: "••••") : .formatted(number: fee.text, currency: "MAS")) } }
            }.listRowBackground(Theme.surface)
            Section(L("Addresses")) {
                LabeledContent(L("From")) { PublicAddressCopyButton(address: operation.sender).font(.caption.monospaced()) }
                if let recipient = operation.recipient { LabeledContent(L("To")) { PublicAddressCopyButton(address: recipient).font(.caption.monospaced()) } }
            }.listRowBackground(Theme.surface)
            Section {
                if let url = operation.explorerURL { Link("Open Mainnet explorer", destination: url) }
                Text(L("History and execution labels are provided by the official explorer indexer, not independently verified consensus proofs.")).font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Theme.surface)
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle(L("Operation")).navigationBarTitleDisplayMode(.inline)
    }
}

struct HistoryRefreshButton: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    let address: String
    @Environment(MainnetHistory.self) private var history
    var body: some View {
        let _ = liveLanguage.language
        Button { Task { await history.refresh(address, force: true) } } label: {
            if history.loading.contains(address) { ProgressView().frame(width: 44, height: 44) }
            else { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
        }.disabled(history.loading.contains(address)).accessibilityLabel(L("Refresh activity"))
    }
}
struct HistoryModePicker: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    @Environment(HistoryPreferences.self) private var preferences
    var body: some View {
        let _ = liveLanguage.language
        HStack(spacing: 8) {
            ForEach(HistoryMode.allCases) { mode in
                Button { preferences.mode = mode } label: {
                    Group {
                        if mode == .sent { Image(systemName: "arrow.up.right") }
                        else if mode == .received { Image(systemName: "arrow.down.left") }
                        else { Text(mode == .smartContracts ? "ASC" : liveLanguage.text(mode.titleKey)).minimumScaleFactor(0.75).lineLimit(1) }
                    }.font(.subheadline.weight(.semibold)).dynamicTypeSize(...DynamicTypeSize.xxxLarge).frame(maxWidth: .infinity).frame(minHeight: 44)
                        .foregroundStyle(preferences.mode == mode ? Theme.accent : Color.secondary)
                        .background(preferences.mode == mode ? Theme.accent.opacity(0.12) : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(preferences.mode == mode ? Theme.accent.opacity(0.4) : Color.secondary.opacity(0.12)))
                }.buttonStyle(.plain).accessibilityIdentifier("history.filter." + mode.rawValue)
                    .accessibilityLabel(liveLanguage.text(mode.accessibilityKey))
                    .accessibilityAddTraits(preferences.mode == mode ? .isSelected : [])
            }
        }.frame(maxWidth: .infinity).accessibilityLabel(L("Activity filter"))
    }
}

/// Normal lists intentionally omit service diagnostics; details retain truthful freshness and failures.
enum HistoryListPresentation {
    enum Status: Equatable { case quiet, loading, empty }
    static func status(_ state: HistoryLoadState) -> Status {
        switch state { case .loading: .loading; case .empty: .empty; default: .quiet }
    }
    static func showStatus(_ row: MainnetOperation) -> Bool { row.status != "Final" || row.executionSucceeded != true }
    static func statusLabel(_ row: MainnetOperation) -> String {
        if row.status != "Final" { return L("Not final") }
        return row.executionSucceeded == false ? L("Failed") : L("Execution unknown")
    }
    static func amount(_ row: MainnetOperation, hidden: Bool) -> String {
        if hidden { return "••••" }
        return row.amount.map { $0.text + " MAS" } ?? "—"
    }
    static func timestamp(_ date: Date?, locale: Locale, timeZone: TimeZone) -> String {
        guard let date else { return "—" }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone))
    }
}
struct HistoryInfoButton: View {
    @Environment(MainnetHistory.self) private var history
    @Environment(AppLanguageSettings.self) private var language
    let address: String
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Image(systemName: "info.circle").frame(width: 44, height: 44) }
            .accessibilityLabel(language.text("Activity details"))
            .sheet(isPresented: $showing) {
                NavigationStack {
                    List {
                        if let fetched = history.updated[address] {
                            LabeledContent(language.text("History fetched"), value: localizedDate(fetched))
                            if history.stale(address) { Text(language.text("Cached history")) }
                        }
                        if let error = history.failures[address] { Text(error.message) }
                        if !(history.issues[address] ?? []).isEmpty { Text(language.text("Some activity could not be loaded. Refresh to check again.")) }
                    }.navigationTitle(language.text("Activity details"))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(language.text("Done")) { showing = false } } }
                }.presentationDetents([.medium, .large])
            }
    }
}
