#if DEBUG
import LocalAuthentication
import Security
import SwiftUI

/// Opt-in hardware diagnostic. The known-insecure fixture must never hold funds.
/// Receipts contain outcomes only, never key bytes, addresses or authentication material.
struct KeychainSecurityProbeView: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    private enum Action: String, CaseIterable {
        case create, noninteractive, authorize, cancel, cleanup
        var title: String {
            switch self {
            case .create: "Create disposable test item"
            case .noninteractive: "Check without authentication"
            case .authorize: "Authenticate and verify persistence"
            case .cancel: "Test cancellation (cover camera first)"
            case .cleanup: "Remove this test item only"
            }
        }
    }
    private struct Receipt: Codable, Identifiable {
        let id: UUID
        let process: UUID
        let time: Date
        let action: String
        let result: String
        let status: OSStatus?
    }
    private static let service = "com.massivex.security-gate.0.3.1.public-probe"
    private let process = UUID()
    @State private var receipts: [Receipt] = []
    @State private var recordingFailed = false
    private var journal: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("security-gate-0.3.1.json")
    }
    var body: some View {
        let _ = liveLanguage.language
        NavigationStack {
            List {
                Section {
                    Text("Physical Keychain probe").font(.headline)
                    Text("DEBUG ONLY · PUBLIC TEST FIXTURE · NEVER FUND")
                    Text("Uses a dedicated test item. No wallet, Receive address, recovery or transfer is enabled.")
                        .font(.footnote)
                    Text("Policy: passcode required, device only, user presence. Approve authentication only for the authorization check; cancel the cancellation check.")
                        .font(.footnote)
                }
                Section("Checks") {
                    ForEach(Action.allCases, id: \.self) { action in
                        Button(action.title) { perform(action) }
                    }
                }
                Section("Outcome receipts") {
                    if recordingFailed { Text("Receipt persistence failed. Do not claim a verified result.") }
                    ForEach(receipts.reversed()) { receipt in
                        VStack(alignment: .leading) {
                            Text(receipt.action + ": " + receipt.result)
                            if let status = receipt.status { Text("OSStatus \(status)") }
                        }.font(.footnote)
                    }
                }
            }.navigationTitle("Security test")
        }
        .interactiveDismissDisabled()
        .task {
            if let data = try? Data(contentsOf: journal) {
                do { receipts = try JSONDecoder().decode([Receipt].self, from: data) }
                catch { recordingFailed = true }
            }
            let prefix = "--security-probe-action="
            if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }),
               let action = Action(rawValue: String(argument.dropFirst(prefix.count))) { perform(action) }
        }
    }
    private func record(_ action: Action, _ result: String, status: OSStatus? = nil) {
        receipts.append(Receipt(id: UUID(), process: process, time: Date(), action: action.rawValue,
                                result: result, status: status))
        do { try JSONEncoder().encode(receipts).write(to: journal, options: [.atomic, .completeFileProtection]) }
        catch { recordingFailed = true }
    }
    private func perform(_ action: Action) {
        #if targetEnvironment(simulator)
        record(action, "BLOCKED: physical iPhone required")
        #else
        let store = TestAccountKeychain(service: Self.service, account: LegacyWalletMigration.account)
        // Deliberately PUBLIC zero-pattern fixture, identical across app processes.
        // No random/user key is needed to prove protected persistence.
        let fixture = Data(repeating: 0, count: 32)
        do {
            switch action {
            case .create:
                try store.saveNew(fixture)
                record(action, "CREATED", status: errSecSuccess)
            case .cleanup:
                try store.delete()
                record(action, "REMOVED (dedicated test item only)", status: errSecSuccess)
            case .noninteractive, .authorize, .cancel:
                let context: LAContext?
                if action == .noninteractive { context = nil }
                else {
                    let fresh = LAContext()
                    fresh.localizedReason = "Verify access to a disposable public Keychain test item."
                    fresh.touchIDAuthenticationAllowableReuseDuration = 0
                    context = fresh
                }
                defer { context?.invalidate() }
                let value = try store.load(context: context)
                if value == nil { record(action, "MISSING") }
                else if value != fixture { record(action, "FAIL: fixture mismatch") }
                else { record(action, action == .authorize ? "AUTHORIZED: persisted fixture matches" : "FAIL: read succeeded", status: errSecSuccess) }
            }
        } catch TestAccountStorageError.keychain(let status) {
            // Classification remains literal: a status is evidence, not a device-security verdict.
            record(action, "REJECTED", status: status)
        } catch { record(action, "FAILED: storage error (no material recorded)") }
        #endif
    }
}
#endif
