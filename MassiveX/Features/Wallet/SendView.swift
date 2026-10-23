import SwiftUI

/// Metadata eligibility never claims a protected key is accessible before authentication.
enum SendAvailability: Equatable {
    case noWallet, watchOnly, archived, invalidIdentity, available
    static func evaluate(_ wallet: ManagedWallet?) -> Self {
        guard let wallet else { return .noWallet }
        if wallet.isQuarantined || wallet.storage != .current || wallet.network != "Mainnet" { return .archived }
        if wallet.kind == .watchOnly { return .watchOnly }
        return (try? SendWallet(wallet)) == nil ? .invalidIdentity : .available
    }
    var reason: String {
        switch self {
        case .noWallet, .invalidIdentity: SendFailure.wallet.message
        case .watchOnly: L("This is a watch-only address. No signing key is stored for it.")
        case .archived: L("Archived preview accounts cannot send or be funded. Keep any independent backup; create a new Mainnet wallet instead.")
        case .available: SendDisclosure.text
        }
    }
}
struct SendView: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    @Environment(WalletManager.self) private var wallets
    @Environment(SendCoordinator.self) private var send
    @Environment(MainnetHistory.self) private var history
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var recipient = ""
    @State private var amount = ""
    @State private var rejectedAmount = false
    @Environment(WalletState.self) private var privacy
    @State private var loadingMax = false
    @State private var maxFailure: SendFailure?
    @State private var formGeneration = UUID()
    @State private var showingRecent = false
    @State private var showingCredit = false
    @State private var gesture = SlideSubmissionState()
    @State private var amountFocused = false
    private enum Field { case recipient }
    @FocusState private var focused: Field?
    private var wallet: SendWallet? { wallets.selected.flatMap { try? SendWallet($0) } }
    var body: some View {
        let _ = liveLanguage.language
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                if let issue = send.journalIssue {
                    Text(issue.message).font(.footnote).foregroundStyle(Theme.warning)
                    Button(L("Retry protected storage")) { send.reloadJournal() }.disabled(send.busy)
                }
                if let wallet {
                    if let pending = send.unresolved(wallet) {
                        statusContent(draft: pending.draft, kind: pending.state == .pending ? .pending : .unknown)
                        if send.busy { ProgressView() }
                        Button(L("Check status")) { Task { await send.reconcile(pending) } }.disabled(send.busy)
                        Button(L("Review historical payment")) {
                            send.historicalPrivacy(active: phase == .active, captured: UIScreen.main.isCaptured)
                            Task { await send.prepareHistoricalRecovery(pending) }
                        }.disabled(send.busy)
                        if let message = send.message { Text(message).font(.footnote).foregroundStyle(Theme.warning) }
                    } else if let receipt = send.review, let kind = SendStatusPresentation.terminal(send.phase) {
                        let stored = send.pending.first { $0.draft.operationID == receipt.operationID }
                        statusContent(draft: receipt, kind: stored?.assessment?.historicalResolution != nil ? .historical : kind)
                    } else if let review = send.review, send.phase == .review || send.phase == .awaitingAuthentication {
                        reviewContent(review)
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L("Recipient")).font(.caption).foregroundStyle(.secondary)
                                HStack(alignment: .center, spacing: 12) {
                                    TextField(L("Massa AU address"), text: $recipient, axis: .vertical)
                                        .lineLimit(2...3).font(.body).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused, equals: .recipient)
                                        .accessibilityIdentifier("send.recipient")
                                    CompactPasteButton(label: L("Paste")) { values in recipient = (values.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                                    Button { dismissKeyboard(); showingRecent = true } label: { Image(systemName: "clock.arrow.circlepath").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel(L("Recent recipients"))
                                }.frame(minHeight: 58)
                                if !recipient.isEmpty && !SendFormPresentation.validRecipient(recipient) {
                                    Text(L("Enter a valid Massa user address (AU).")).font(.caption).foregroundStyle(.secondary)
                                }
                            }.surfaceCard()
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L("Amount")).font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 14) {
                                    AmountEntryField(text: $amount, isFocused: $amountFocused, rejected: $rejectedAmount)
                                        .frame(minHeight: 48)
                                    Text("MAS").font(.headline).foregroundStyle(Theme.accent)
                                        .padding(12).background(Theme.accent.opacity(0.12), in: Capsule())
                                }.frame(minHeight: 58)
                                if rejectedAmount { Text(L("Enter a valid amount with up to 9 decimal places.")).font(.caption).foregroundStyle(.secondary) }
                            }.surfaceCard()
                            HStack(alignment: .firstTextBaseline) {
                                Text(L("Balance") + ": " + availableText).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                Button { loadMaximum(wallet) } label: {
                                    if loadingMax { ProgressView() } else { Text(L("Max")).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(height: 36).background(Theme.accent.opacity(0.12), in: Capsule()) }
                                }.frame(minWidth: 44, minHeight: 44).disabled(send.busy || loadingMax || !SendFormPresentation.validRecipient(recipient))
                                    .accessibilityLabel(L("Use maximum amount"))
                            }
                            if let maxFailure { Text(maxFailure.message).font(.footnote).foregroundStyle(Theme.warning) }
                            Button(L("Continue")) { dismissKeyboard(); Task { await send.prepare(wallet: wallet, recipient: recipient, amount: (try? MASUserInput.parse(amount).text) ?? "") } }
                                .buttonStyle(PrimaryButtonStyle()).opacity(SendFormPresentation.canContinue(recipient: recipient, amount: amount, busy: send.busy || loadingMax || rejectedAmount) ? 1 : 0.45)
                                .disabled(!SendFormPresentation.canContinue(recipient: recipient, amount: amount, busy: send.busy || loadingMax || rejectedAmount))
                                .accessibilityIdentifier("send.continue")
                        }
                    }
                    if send.busy && send.unresolved(wallet) == nil { ProgressView() }
                    if send.unresolved(wallet) == nil, let message = send.message { Text(message).font(.footnote).foregroundStyle(Theme.warning) }
                } else { Text(SendAvailability.evaluate(wallets.selected).reason) }
                }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively).background(Theme.background).navigationTitle(send.phase == .review ? L("Review transfer") : L("Send"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if send.phase == .review { Button { send.invalidateReview() } label: { Image(systemName: "chevron.left") }.accessibilityLabel(L("Back")) }
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button { send.invalidateReview(); dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2).symbolRenderingMode(.hierarchical) }.accessibilityLabel(L("Close")) }
                    ToolbarItemGroup(placement: .keyboard) { if focused == .recipient { Spacer(); Button(L("Done")) { dismissKeyboard() } } }
                }
                .sheet(isPresented: $showingRecent) {
                    NavigationStack {
                        List {
                            if let wallet {
                                let rows = SendRecentRecipients.make(send.pending, for: wallet)
                                if rows.isEmpty { ContentUnavailableView(L("No recent recipients"), systemImage: "clock", description: Text(L("Confirmed outgoing payments from this wallet appear here."))) }
                                ForEach(rows) { row in
                                    Button { guard self.wallet?.sourceIdentity == wallet.sourceIdentity else { showingRecent = false; return }; recipient = row.address; showingRecent = false } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(SendFormPresentation.shortAddress(row.address)).font(.body.monospaced())
                                            Text(row.date.formatted(.dateTime.locale(liveLanguage.language.locale))).font(.caption).foregroundStyle(.secondary)
                                        }.frame(minHeight: 44)
                                    }.accessibilityLabel(row.address)
                                }
                            }
                        }.navigationTitle(L("Recent recipients"))
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { showingRecent = false } } }
                    }.presentationDetents([.medium, .large])
                }
                .sheet(isPresented: Binding(get: { send.historicalReview != nil }, set: { if !$0 { send.cancelHistoricalRecovery() } })) {
                    if let historical = send.historicalReview { historicalContent(historical) }
                }
                .onAppear { send.historicalPrivacy(active: phase == .active, captured: UIScreen.main.isCaptured) }
                .onChange(of: recipient) { _, _ in gesture.reset(); formGeneration = UUID(); maxFailure = nil; send.invalidateReview() }
                .onChange(of: rejectedAmount) { _, _ in send.invalidateReview() }
                .onChange(of: amount) { _, _ in rejectedAmount = false; gesture.reset(); formGeneration = UUID(); send.invalidateReview() }
                .onChange(of: wallets.selectedID) { _, _ in dismissKeyboard(); showingRecent = false; showingCredit = false; gesture.reset(); formGeneration = UUID(); recipient = ""; amount = ""; send.select(wallet) }
                .onChange(of: phase) { _, value in
                    send.historicalPrivacy(active: value == .active, captured: UIScreen.main.isCaptured, background: value == .background)
                    wallets.backup?.updatePrivacy(active: value == .active, captured: UIScreen.main.isCaptured, background: value == .background)
                    if value == .background { dismissKeyboard(); showingRecent = false; showingCredit = false; gesture.reset(); send.invalidateReview() }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                    send.historicalPrivacy(active: phase == .active, captured: UIScreen.main.isCaptured)
                    wallets.backup?.updatePrivacy(active: phase == .active, captured: UIScreen.main.isCaptured)
                    if UIScreen.main.isCaptured { dismissKeyboard(); showingRecent = false; showingCredit = false; gesture.reset(); send.invalidateReview() }
                }
                .onChange(of: send.phase) { _, value in
                    if [.pending, .finalized, .failed].contains(value), let wallet {
                        Task { await wallets.refreshBalance(wallet.id, force: true); await history.refresh(wallet.address, force: true) }
                    }
                }
                .task { send.select(wallet); if let wallet, let pending = send.unresolved(wallet) { await send.reconcile(pending) } }
                .onDisappear { dismissKeyboard(); showingRecent = false; showingCredit = false; gesture.reset(); send.invalidateReview() }
        }
        .preferredColorScheme(.dark)
    }
    private func dismissKeyboard() { focused = nil; amountFocused = false }
    private func submit(_ approved: ReviewedTransfer) {
        guard send.review == approved, wallet?.sourceIdentity == approved.wallet.sourceIdentity,
              wallet?.id == approved.wallet.id, phase == .active, !UIScreen.main.isCaptured,
              !send.busy, let access = wallets.backup else { gesture.reset(); return }
        access.updatePrivacy(active: true, captured: false)
        Task { @MainActor in
            await send.confirm(approved: approved, signer: ProtectedTransferSigner(access: access))
            gesture.reset()
        }
    }
    private func operationDetails(_ id: String) -> some View {
        DisclosureGroup(L("Transaction details")) {
            Text(id).font(.caption.monospaced()).textSelection(.enabled)
            Text(SendStatusPresentation.evidenceMessage(send.pending.first { $0.draft.operationID == id })).font(.caption).foregroundStyle(.secondary)
            Button(L("Copy operation ID")) { UIPasteboard.general.string = id }
            if let url = URL(string: "https://explorer.massa.net/mainnet/operation/" + id) { Link(L("Open in Massa Explorer"), destination: url) }
        }.font(.footnote)
    }
    private func statusContent(draft: ReviewedTransfer, kind: SendStatusPresentation) -> some View {
        VStack(spacing: 20) {
            Image(systemName: kind.symbol).font(.system(size: 52, weight: .light))
                .foregroundStyle(kind == .completed ? Color.green : kind == .unknown ? Theme.warning : Color.secondary)
                .accessibilityHidden(true)
            Text(L(kind.title)).font(.largeTitle.bold())
            if kind == .completed || kind == .historical {
                CurrencyAmountText(parts: .formatted(number: MASUserInput.display(draft.amount, locale: liveLanguage.language.locale), currency: "MAS")).font(.title2).monospacedDigit()
                Text(L("Recipient") + " · " + SendFormPresentation.shortAddress(draft.recipient)).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(L(kind.guidance)).font(.subheadline).foregroundStyle(kind == .unknown ? Theme.warning : Color.secondary).multilineTextAlignment(.center)
            operationDetails(draft.operationID).frame(maxWidth: .infinity, alignment: .leading).surfaceCard()
            if kind == .completed || kind == .failed || kind == .historical, let wallet, send.unresolved(wallet) == nil {
                Button(L("New transfer")) {
                    if send.beginNewTransfer(for: wallet) { recipient = ""; amount = ""; gesture.reset() }
                }.buttonStyle(PrimaryButtonStyle()).disabled(send.busy)
            }
            Button(L("Back to Wallet")) { send.invalidateReview(); dismiss() }.buttonStyle(PrimaryButtonStyle())
        }.padding(.vertical, 24).frame(maxWidth: .infinity)
    }
    private func historicalContent(_ historical: HistoricalRecoveryReview) -> some View {
        NavigationStack {
            List {
                Section(L("Historical payment found")) {
                    Text(L("The official Explorer reports Final and Success. Its signature and payment details match this stored intent."))
                    Text(L("This is indexed historical evidence, not RPC confirmation or independent consensus verification. Authenticate only if you accept this specific result."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent(L("From")) { Text(historical.draft.wallet.address).textSelection(.enabled).font(.caption.monospaced()) }
                    LabeledContent(L("Recipient")) { Text(historical.draft.recipient).textSelection(.enabled).font(.caption.monospaced()) }
                    LabeledContent(L("Evidence source"), value: "explorer-api.massa.net · Mainnet")
                    LabeledContent(L("Amount"), value: historical.draft.amount.text + " MAS")
                    LabeledContent(L("Fee"), value: historical.draft.fee.text + " MAS")
                    Text(historical.draft.operationID).font(.caption.monospaced()).textSelection(.enabled)
                    if let report = historical.evidence.reports.first {
                        Text(report.block.hash).font(.caption.monospaced()).textSelection(.enabled)
                        if let millis = UInt64(report.operation.timestamp) { Text(Date(timeIntervalSince1970: Double(millis) / 1000).formatted(.dateTime.locale(liveLanguage.language.locale))) }
                    }
                    Link(L("Open in Massa Explorer"), destination: URL(string: "https://explorer.massa.net/mainnet/operation/" + historical.draft.operationID)!)
                }
                Section {
                    Text(L("This does not send or retry a payment.")).font(.footnote)
                    Button(L("Authenticate and accept historical result")) { Task { await send.confirmHistoricalRecovery(historical) } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(send.busy || phase != .active || UIScreen.main.isCaptured)
                    if send.busy { ProgressView() }
                    if let message = send.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
            }.navigationTitle(L("Review historical payment")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { send.cancelHistoricalRecovery() } } }
        }
    }
    private var availableText: String {
        guard let id = wallets.selectedID, wallets.balanceErrors[id] == nil,
              let updated = wallets.lastUpdated[id], (0...20).contains(Date().timeIntervalSince(updated)),
              let balance = wallets.balances[id], let final = try? MASAmount(balance.finalBalance),
              let candidate = try? MASAmount(balance.candidateBalance) else { return "—" }
        return privacy.balanceHidden ? "••••" : SendBalancePresentation.text(min(final, candidate), locale: liveLanguage.language.locale) + " MAS"
    }
    private func loadMaximum(_ wallet: SendWallet) {
        let address = recipient, generation = formGeneration
        loadingMax = true; maxFailure = nil
        Task { @MainActor in
            defer { loadingMax = false }
            do {
                // Existing read-only preflight supplies fee reservation; Continue still prepares the real review.
                let snapshot = try await MainnetTransferRPC().snapshot(source: wallet.address, recipient: address)
                try snapshot.validate(now: Date())
                guard formGeneration == generation, self.wallet?.id == wallet.id else { return }
                guard let maximum = SendFormPresentation.maximum(spendable: snapshot.spendable, fee: snapshot.fee) else { maxFailure = .funds; return }
                rejectedAmount = false
                amount = MASUserInput.display(maximum, locale: liveLanguage.language.locale)
            } catch { if formGeneration == generation { maxFailure = .network } }
        }
    }
    private func reviewContent(_ review: ReviewedTransfer) -> some View {
        VStack(spacing: 24) {
            MassaCurrencySymbol(size: 72)
            VStack(spacing: 6) {
                Text(L("MAS transfer")).font(.subheadline).foregroundStyle(.secondary)
                CurrencyAmountText(parts: .formatted(number: MASUserInput.display(review.amount, locale: liveLanguage.language.locale), currency: "MAS")).font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit().multilineTextAlignment(.center)
            }
            VStack(spacing: 18) {
                ReviewedAddressRow(title: L("From"), address: review.wallet.address, detail: (wallets.selected?.name ?? L("Wallet")) + " · " + SendFormPresentation.shortAddress(review.wallet.address))
                ReviewedAddressRow(title: L("Recipient"), address: review.recipient, detail: SendFormPresentation.shortAddress(review.recipient))
                Divider()
                LabeledContent {
                    CurrencyAmountText(parts: .formatted(number: MASUserInput.display(review.amount, locale: liveLanguage.language.locale), currency: "MAS"))
                } label: {
                    HStack { Text(L("Amount")); if review.recipientCredit?.creationPossible == true { Button { showingCredit = true } label: { Image(systemName: "info.circle").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel(L("Recipient amount details")) } }
                }.popover(isPresented: $showingCredit) { VStack(alignment: .leading, spacing: 12) {
                    Text(L("Recipient amount details")).font(.headline)
                    Text(L("Recipient state can change before execution. Account creation deducts 0.001 MAS from the amount; transfers below that cost fail if creation becomes necessary."))
                    Button(L("Done")) { showingCredit = false }
                }.padding(20).presentationCompactAdaptation(.popover) }
                LabeledContent(L("Network fee")) { CurrencyAmountText(parts: .formatted(number: MASUserInput.display(review.fee, locale: liveLanguage.language.locale), currency: "MAS")) }
                LabeledContent(L("Total")) { CurrencyAmountText(parts: .formatted(number: MASUserInput.display(review.total, locale: liveLanguage.language.locale), currency: "MAS")) }.fontWeight(.semibold)

            }.surfaceCard()
            SlideToSubmitControl(state: $gesture, enabled: !send.busy && phase == .active && !UIScreen.main.isCaptured,
                                 identity: review.operationID) { submit(review) }
                .accessibilityIdentifier("send.confirm")
            Text(L(SendDisclosure.text)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// View-only input/formatting helpers; the unchanged coordinator validates the actual transaction.
enum SendFormPresentation {
    static func validRecipient(_ text: String) -> Bool { (try? MassaPublicAccount.validateUserAddress(text)) != nil }
    static func canContinue(recipient: String, amount: String, busy: Bool) -> Bool {
        !busy && validRecipient(recipient) && (try? MASUserInput.parse(amount)).map { $0.nano > 0 } == true
    }
    static func maximum(spendable: MASAmount, fee: MASAmount) -> MASAmount? {
        spendable > fee ? MASAmount(nano: spendable.nano - fee.nano) : nil
    }
    static func shortAddress(_ address: String) -> String { String(address.prefix(7)) + "…" + address.suffix(6) }
}

struct RecentSendRecipient: Identifiable, Equatable {
    let address: String
    let date: Date
    var id: String { address }
}
enum SendRecentRecipients {
    static func make(_ records: [PendingTransfer], for wallet: SendWallet) -> [RecentSendRecipient] {
        var latest: [String: Date] = [:]
        for record in records where record.draft.wallet.sourceIdentity == wallet.sourceIdentity && record.state == .finalized && record.hasTrustedResolution {
            guard let date = (record.assessment?.providerResolution?.acceptedAt ?? record.assessment?.historicalResolution?.acceptedAt),
                  SendFormPresentation.validRecipient(record.draft.recipient) else { continue }
            latest[record.draft.recipient] = max(latest[record.draft.recipient] ?? .distantPast, date)
        }
        return latest.map { RecentSendRecipient(address: $0.key, date: $0.value) }
            .sorted { $0.date == $1.date ? $0.address < $1.address : $0.date > $1.date }
    }
}

/// A UI commit latch, never transaction authority. The coordinator still validates/authenticates.
struct SlideSubmissionState: Equatable {
    private(set) var progress: CGFloat = 0
    private(set) var consumed = false
    private(set) var rejected = false
    mutating func update(horizontal: CGFloat, vertical: CGFloat, travel: CGFloat) {
        guard !consumed, !rejected else { return }
        guard travel >= 100, abs(vertical) <= 32, horizontal >= 0 else { rejected = true; progress = 0; return }
        progress = min(1, horizontal / travel)
    }
    mutating func finish(enabled: Bool) -> Bool {
        guard !consumed else { return false }
        guard enabled, !rejected, progress >= 0.98 else { reset(); return false }
        consumed = true; progress = 1; return true
    }
    mutating func accessibleCommit(enabled: Bool) -> Bool {
        guard enabled, !consumed else { return false }
        consumed = true; progress = 1; return true
    }
    mutating func reset() { self = Self() }
}
struct SlideToSubmitControl: View {
    @Binding var state: SlideSubmissionState
    let enabled: Bool
    let identity: String
    let submit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppLanguageSettings.self) private var language
    var body: some View {
        let _ = language.language
        GeometryReader { geometry in
            let travel = max(0, geometry.size.width - 64)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 18).fill(Theme.accent.opacity(0.12))
                Text(language.text("Slide to Submit")).font(.headline).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    .padding(.leading, 64).padding(.trailing, 12).frame(maxWidth: .infinity)
                    .opacity(1 - state.progress)
                Image(systemName: state.consumed ? "lock.shield" : "arrow.right").font(.title3.weight(.bold))
                    .foregroundStyle(Color.black).frame(width: 52, height: 52)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    .offset(x: 6 + travel * state.progress)
                    .gesture(DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            guard enabled, value.startLocation.x >= 0, value.startLocation.x <= 52 else { return }
                            state.update(horizontal: value.translation.width, vertical: value.translation.height, travel: travel)
                        }
                        .onEnded { value in
                            state.update(horizontal: value.translation.width, vertical: value.translation.height, travel: travel)
                            if state.finish(enabled: enabled) { commit() }
                        })
            }.opacity(enabled ? 1 : 0.5)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.consumed)
        }.frame(height: 64)
            .accessibilityElement(children: .ignore).accessibilityLabel(language.text("Slide to Submit"))
            .accessibilityHint(language.text("Double-tap to confirm the reviewed transfer and authenticate."))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if state.accessibleCommit(enabled: enabled) { commit() } }
            .onChange(of: identity) { _, _ in state.reset() }
            .onChange(of: enabled) { _, value in if !value && !state.consumed { state.reset() } }
    }
    private func commit() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        submit()
    }
}

/// Presentation never upgrades an acknowledgement to final execution.
enum SendStatusPresentation: Equatable {
    case completed, pending, failed, unknown, historical
    static func evidenceMessage(_ record: PendingTransfer?) -> String {
        if let record, record.hasTrustedResolution, let assessment = record.assessment { return assessment.message }
        if let assessment = record?.assessment, assessment.reason != .trustedMassaLabs && assessment.reason != .ownerReviewedHistorical { return assessment.message }
        return L("Not yet confirmed by Massa Mainnet RPC.")
    }
    static func terminal(_ phase: SendCoordinator.Phase) -> Self? {
        switch phase { case .finalized: .completed; case .failed: .failed; default: nil }
    }
    var title: String { switch self { case .historical: "Historical result accepted"; case .completed: "Completed"; case .pending: "Pending"; case .failed: "Not completed"; case .unknown: "Status unknown" } }
    var guidance: String { switch self {
        case .historical: "Accepted after your authenticated review of official Explorer evidence."
        case .completed: "Confirmed on Massa Mainnet"
        case .pending: "Waiting for network confirmation"
        case .failed: "The network reported final execution failure. Check transaction details before making a new payment."
        case .unknown: "Do not send this payment again until you verify its result."
    } }
    var symbol: String { switch self { case .historical: "checkmark.shield"; case .completed: "checkmark.circle"; case .pending: "clock"; case .failed: "xmark.circle"; case .unknown: "questionmark.circle" } }
}
