import SwiftUI
import UniformTypeIdentifiers
import Observation

/// Owns every asynchronous outcome, including rejected protected-store imports.
@MainActor @Observable final class YAMLImportSession {
    private(set) var busy = false
    private(set) var failure: String?
    private var generation = UUID()
    func clearFailure() { if !busy { failure = nil } }
    func cancel() { generation = UUID(); busy = false; failure = "Import cancelled. Choose the file and try again." }
    func importDocument(_ document: MassaYAMLImport.Document, password: String, name: String,
                        wallets: WalletManager, permitted: @escaping @MainActor () -> Bool) async -> Bool {
        guard !busy else { return false }
        guard permitted() else { failure = "Return to the active app and stop screen capture before continuing."; return false }
        let token = UUID(); generation = token; busy = true; failure = nil
        defer { if generation == token { busy = false } }
        do {
            let decryption = Task.detached(priority: .userInitiated) { try MassaYAMLImport.decrypt(document, password: password).storageData() }
            var seed = try await withTaskCancellationHandler { try await decryption.value } onCancel: { decryption.cancel() }
            defer { seed.resetBytes(in: 0..<seed.count) }
            guard token == generation else { return false }
            guard !Task.isCancelled, permitted() else { failure = "Import cancelled. Choose the file and try again."; return false }
            let account = try MassaTestAccount(seed: seed)
            let added = await wallets.addOwned(privateKey: try account.backupPrivateKeyEncoding(), name: WalletNamePresentation.importName(name), active: true, captured: false)
            guard token == generation else { return false }
            guard added else { failure = wallets.message ?? "Wallet could not be added. Retry after unlocking the device."; return false }
            return true
        } catch is CancellationError { if token == generation { failure = "Import cancelled. Choose the file and try again." }; return false }
        catch let error as MassaYAMLImport.Failure {
            if token == generation { failure = error == .identity ? "The backup identity does not match its key. Nothing was imported." : "Could not unlock this backup. Check the password and file identity." }
            return false
        } catch { if token == generation { failure = "Wallet could not be added. Retry after unlocking the device." }; return false }
    }
}

struct YAMLWalletImportForm: View {
    var onAdded: () -> Void
    @Environment(AppLanguageSettings.self) private var language
    @Environment(WalletManager.self) private var wallets
    @Environment(\.scenePhase) private var phase
    @Environment(\.isSceneCaptured) private var captured
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var document: MassaYAMLImport.Document?
    @State private var password = ""
    @State private var name = ""
    @State private var fileFailure: String?
    @State private var session = YAMLImportSession()
    @State private var work: Task<Void, Never>?
    @State private var formGeneration = UUID()
    private enum Field { case name, password }
    @State private var focused: Field?
    private var privateScene: Bool { phase == .active && !captured }
    var body: some View {
        let _ = language.language
        Section {
            if let failure = fileFailure ?? session.failure { Text(L(failure)).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("yaml.error") }
            Button { focused = nil; picking = true } label: { Label(L(document == nil ? "Choose encrypted YAML" : "Encrypted file selected"), systemImage: "doc") }
            WalletInputField(title: L("Wallet name (optional)"), text: $name, isFocused: focus(.name), role: .name, identifier: "yaml.name", next: true, onSubmit: { focused = .password }).frame(minHeight: 44)
            HStack(spacing: 12) {
                WalletInputField(title: L("Wallet password"), text: $password, isFocused: focus(.password), role: .backupPassword, identifier: "yaml.password", eraseContent: phase == .background || captured).frame(minHeight: 44).privacySensitive()
                CompactPasteButton(label: L("Paste password")) { values in
                    guard privateScene else { return }
                    // Password whitespace is significant; never trim or normalize it.
                    password = values.first ?? ""; focused = .password
                }.accessibilityIdentifier("yaml.paste-password")
            }
            Text(L("Enter the password you used when creating this YAML wallet file — not a new password.")).font(.footnote).foregroundStyle(.secondary)
            Button(L("Add wallet")) { start() }.buttonStyle(PrimaryButtonStyle())
                .disabled(document == nil || password.isEmpty || !WalletNamePresentation.validOptional(name) || session.busy || !privateScene)
            if session.busy { ProgressView(L("Authenticating…")) }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "yaml") ?? .data, UTType(filenameExtension: "yml") ?? .data]) { result in
            guard phase != .background, !captured else { fileFailure = "Import cancelled. Choose the file and try again."; return }
            do {
                let url = try result.get()
                // Local provider URLs need not grant a new scope. OS file access still enforces permission.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                let bytes = try file.read(upToCount: MassaYAMLImport.maximumBytes + 1) ?? Data()
                document = try MassaYAMLImport.parse(bytes); fileFailure = nil; session.clearFailure()
            } catch CocoaError.userCancelled { fileFailure = "Import cancelled. Choose the file and try again." }
            catch { document = nil; fileFailure = "Unsupported or invalid encrypted YAML. Choose a single-account Version 1 backup." }
        }
        .onChange(of: phase) { _, value in if value == .background { clear() } }
        .onChange(of: captured) { _, value in if value { clear() } }
        .onDisappear { clear() }
    }
    private func focus(_ field: Field) -> Binding<Bool> {
        Binding(get: { focused == field }, set: { value in if value { focused = field } else if focused == field { focused = nil } })
    }
    private func clear() {
        formGeneration = UUID(); session.cancel(); work?.cancel(); work = nil; password = ""; document = nil; focused = nil
        wallets.cancelCreation()
    }
    private func start() {
        guard privateScene, !session.busy, work == nil, let document, !password.isEmpty else { return }
        focused = nil; fileFailure = nil
        let input = password, walletName = name, token = UUID()
        formGeneration = token
        work = Task {
            let success = await session.importDocument(document, password: input, name: walletName, wallets: wallets, permitted: { privateScene })
            guard token == formGeneration, !Task.isCancelled else { return }
            work = nil
            // An intelligible failure is set before clearing a failed password; it remains above the fields.
            password = ""
            if success { self.document = nil; onAdded(); dismiss() }
        }
    }
}
