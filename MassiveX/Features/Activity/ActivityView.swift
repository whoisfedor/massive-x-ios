import SwiftUI

struct ActivityView: View {
    @Environment(SendCoordinator.self) private var send
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
                    let local = send.pending.filter { $0.draft.wallet.address == address }
                        .sorted { $0.draft.reviewedAt > $1.draft.reviewedAt }
                    if !local.isEmpty {
                        Section(L("Submitted from this device")) {
                            ForEach(local, id: \.draft.operationID) { record in
                                NavigationLink { LocalTransferDetailView(operationID: record.draft.operationID) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(L(SendStatusPresentation.history(record).title)).font(.subheadline.weight(.semibold))
                                        Text(SendFormPresentation.shortAddress(record.draft.recipient)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        Text(record.draft.reviewedAt.formatted(.dateTime.locale(liveLanguage.language.locale))).font(.caption).foregroundStyle(.secondary)
                                    }.frame(minHeight: 44)
                                }
                            }
                        }.listRowBackground(Theme.surface)
                    }
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
            if allowsAddressCopy {
                OperationTextColumns() {
                    title
                    amount
                    counterparty
                    timestamp
                    // Measure visible address text separately from its larger interactive frame.
                    counterpartyText.hidden().accessibilityHidden(true)
                    if HistoryListPresentation.showStatus(operation) { status }
                }
            } else {
                // Home's recent row belongs entirely to its operation-details NavigationLink.
                VStack(alignment: .leading, spacing: 4) {
                    title
                    if HistoryListPresentation.showStatus(operation) { status }
                    counterparty
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) { amount; timestamp }
            }
        }.padding(.vertical, 6).accessibilityElement(children: .contain)
    }
    private var title: some View { Text(operation.title(for: address)).font(.subheadline.weight(.semibold)) }
    private var status: some View {
        Text(HistoryListPresentation.statusLabel(operation)).font(.caption)
            .foregroundStyle(operation.executionSucceeded == false ? Theme.warning : Color.secondary)
    }
    @ViewBuilder private var counterparty: some View {
        if let other = operation.shortCounterparty(for: address) {
            if allowsAddressCopy {
                PublicAddressCopyButton(address: operation.sender == address ? (operation.recipient ?? "") : operation.sender,
                    display: other).font(.caption.monospaced()).foregroundStyle(.secondary)
            } else { Text(other).font(.caption.monospaced()).foregroundStyle(.secondary) }
        } else { Color.clear.frame(width: 0, height: 0) }
    }
    @ViewBuilder private var counterpartyText: some View {
        if let other = operation.shortCounterparty(for: address) {
            Text(other).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
        } else { Color.clear.frame(width: 0, height: 0) }
    }
    private var amount: some View {
        CurrencyAmountText(parts: privacy.balanceHidden ? CurrencyDisplayParts(number: "••••") : operation.amount.map { .formatted(number: $0.text, currency: "MAS") } ?? CurrencyDisplayParts(number: "—"))
            .font(.subheadline).monospacedDigit()
    }
    private var timestamp: some View {
        Text(HistoryListPresentation.timestamp(operation.date, locale: liveLanguage.language.locale, timeZone: .current))
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
    }
}

/// Align corresponding text baselines while measuring wrapped labels and the 44-point copy target.
/// Keeping hit-target height separate from baseline placement avoids independently centered columns.
struct OperationTextColumns: Layout {
    struct Cell {
        let size: CGSize
        let firstBaseline: CGFloat
        let lastBaseline: CGFloat
    }
    struct Placement {
        let size: CGSize
        let origins: [CGPoint]
        let contentFrame: CGRect
    }
    static func arrange(width: CGFloat, cells: [Cell], addressText: Cell) -> Placement {
        // Preserve the prior row budget, which included a top-aligned 44-point copy frame.
        var budgetCells = cells
        budgetCells[2] = Cell(size: cells[2].size, firstBaseline: addressText.firstBaseline, lastBaseline: addressText.lastBaseline)
        let budget = uncentered(width: width, cells: budgetCells)
        var textCells = cells
        textCells[2] = addressText
        let text = uncentered(width: width, cells: textCells)
        let height = max(budget.size.height, text.size.height)
        let top = (height - text.size.height) / 2
        var origins = text.origins.map { CGPoint(x: $0.x, y: $0.y + top) }
        // The button remains >=44 points and centered around its label, wholly inside the row.
        origins[2].y += addressText.lastBaseline - cells[2].lastBaseline
        return Placement(size: CGSize(width: width, height: height), origins: origins,
            contentFrame: CGRect(x: 0, y: top, width: width, height: text.size.height))
    }
    private static func uncentered(width: CGFloat, cells: [Cell]) -> Placement {
        let gap: CGFloat = 4
        var origins = [CGPoint](repeating: .zero, count: cells.count)
        let firstBaseline = max(cells[0].firstBaseline, cells[1].firstBaseline)
        origins[0].y = firstBaseline - cells[0].firstBaseline
        origins[1] = CGPoint(x: width - cells[1].size.width, y: firstBaseline - cells[1].firstBaseline)
        var nextY = max(origins[0].y + cells[0].size.height, origins[1].y + cells[1].size.height) + gap
        if cells.count == 5 {
            origins[4].y = nextY
            nextY += cells[4].size.height + gap
        }
        let lastBaseline = max(cells[2].lastBaseline, cells[3].lastBaseline)
        origins[2].y = nextY + lastBaseline - cells[2].lastBaseline
        origins[3] = CGPoint(x: width - cells[3].size.width, y: nextY + lastBaseline - cells[3].lastBaseline)
        let height = max(origins[2].y + cells[2].size.height, origins[3].y + cells[3].size.height)
        return Placement(size: CGSize(width: width, height: height), origins: origins, contentFrame: CGRect(x: 0, y: 0, width: width, height: height))
    }
    private func measure(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (Placement, [ProposedViewSize]) {
        let idealRight = max(subviews[1].sizeThatFits(.unspecified).width, subviews[3].sizeThatFits(.unspecified).width)
        let idealLeft = max(subviews[0].sizeThatFits(.unspecified).width, subviews[2].sizeThatFits(.unspecified).width)
        let width = max(0, proposal.width ?? (idealLeft + idealRight + 4))
        // Preserve room for both columns; wrapped accessibility labels receive their full natural height.
        let rightWidth = min(idealRight, width * 0.55)
        let leftWidth = max(0, width - rightWidth - 4)
        // The hidden fifth subview supplies only the public label's intrinsic text dimensions.
        let indices = [0, 1, 2, 3] + (subviews.count == 6 ? [5] : [])
        let proposals = subviews.indices.map { ProposedViewSize(width: $0 == 1 || $0 == 3 ? rightWidth : leftWidth, height: nil) }
        func cell(_ index: Int) -> Cell {
            let dimensions = subviews[index].dimensions(in: proposals[index])
            return Cell(size: CGSize(width: dimensions.width, height: dimensions.height),
                firstBaseline: dimensions[.firstTextBaseline], lastBaseline: dimensions[.lastTextBaseline])
        }
        return (Self.arrange(width: width, cells: indices.map(cell), addressText: cell(4)), proposals)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measure(proposal, subviews).0.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (placement, proposals) = measure(ProposedViewSize(width: bounds.width, height: nil), subviews)
        let indices = [0, 1, 2, 3] + (subviews.count == 6 ? [5] : [])
        for (position, index) in indices.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + placement.origins[position].x, y: bounds.minY + placement.origins[position].y),
                anchor: .topLeading, proposal: proposals[index])
        }
        subviews[4].place(at: bounds.origin, anchor: .topLeading, proposal: proposals[4])
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

/// Local submission evidence is separate from the Explorer's on-chain history.
/// Merely dismissing this screen never resolves, deletes or resubmits an operation.
struct LocalTransferDetailView: View {
    let operationID: String
    @Environment(SendCoordinator.self) private var send
    @Environment(AppLanguageSettings.self) private var language
    @Environment(WalletState.self) private var privacy
    @State private var refreshFailed = false
    var body: some View {
        let _ = language.language
        List {
            if let record = send.pending.first(where: { $0.draft.operationID == operationID }) {
                let status = SendStatusPresentation.history(record)
                Section {
                    LabeledContent(L("Status"), value: L(status.title))
                    Text(L(status.guidance)).font(.footnote).foregroundStyle(.secondary)
                    Text(SendStatusPresentation.evidenceMessage(record)).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent(L("Amount"), value: privacy.balanceHidden ? "••••" : record.draft.amount.text + " MAS")
                    LabeledContent(L("Network fee"), value: privacy.balanceHidden ? "••••" : record.draft.fee.text + " MAS")
                    LabeledContent(L("Recipient")) { Text(SendFormPresentation.shortAddress(record.draft.recipient)).font(.caption.monospaced()) }
                    Text(operationID).font(.caption.monospaced()).textSelection(.enabled)
                    Button(L("Copy operation ID")) { UIPasteboard.general.string = operationID }
                    Link(L("Open in Massa Explorer"), destination: URL(string: "https://explorer.massa.net/mainnet/operation/" + operationID)!)
                    Button {
                        Task {
                            refreshFailed = false
                            await send.reconcile(record)
                            refreshFailed = send.pending.first(where: { $0.draft.operationID == operationID })?.assessment?.checkedAt == record.assessment?.checkedAt
                        }
                    } label: { Label(L("Check status"), systemImage: "arrow.clockwise") }
                    .disabled(send.busy || send.reconcilingIDs.contains(operationID) || record.hasTrustedResolution)
                    if send.reconcilingIDs.contains(operationID) { ProgressView() }
                    if refreshFailed { Text(L("Status unavailable")).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle(L("Transaction details")).navigationBarTitleDisplayMode(.inline)
    }
}
