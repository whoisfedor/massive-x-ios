import XCTest
import SwiftUI
import UIKit
import LocalAuthentication
@testable import MassiveX

@MainActor private final class ComposingAmountField: UITextField {
    var composing = false
    override var markedTextRange: UITextRange? { composing ? selectedTextRange : nil }
}
@MainActor final class FinalPhoneUXTests: XCTestCase {
    func testEnglishDotRussianCommaAndPastePreserveCaretAndExactNano() throws {
        for separator in [".", ","] {
            let edit = try XCTUnwrap(AmountTextEdit.apply("025", range: NSRange(location: 1, length: 0), replacement: separator))
            XCTAssertEqual(edit.text, "0.25"); XCTAssertEqual(edit.caret, 2)
            XCTAssertEqual(try MASUserInput.parse(edit.text).nano, 250_000_000)
        }
        let paste = try XCTUnwrap(AmountTextEdit.apply("", range: NSRange(location: 0, length: 0), replacement: "0,123456789"))
        XCTAssertEqual(paste.text, "0.123456789"); XCTAssertEqual(paste.caret, 11)
        XCTAssertEqual(try MASUserInput.parse(paste.text).nano, 123_456_789)
        XCTAssertEqual(AmountTextEdit.apply("123", range: NSRange(location: 0, length: 1), replacement: "0,"), .init(text: "0.23", caret: 2))
        XCTAssertEqual(AmountTextEdit.apply("1.25", range: NSRange(location: 1, length: 1), replacement: ""), .init(text: "125", caret: 1))
        XCTAssertEqual(AmountTextEdit.apply("1.25", range: NSRange(location: 0, length: 4), replacement: ""), .init(text: "", caret: 0))
    }
    func testMalformedGroupedSecondSeparatorAndPrecisionFailClosed() {
        for raw in ["1,2.3", "1.2,3", "1,000,000", "1 000", "-1", "+1", "1e2", "1_000", "0.1234567891", " 0.25", "NaN"] {
            XCTAssertNil(AmountTextEdit.apply("", range: NSRange(location: 0, length: 0), replacement: raw))
            XCTAssertThrowsError(try MASUserInput.parse(raw))
        }
        XCTAssertNil(AmountTextEdit.apply("0.25", range: NSRange(location: 1, length: 0), replacement: ","))
        XCTAssertNil(AmountTextEdit.apply("1", range: NSRange(location: 8, length: 1), replacement: "2"))
        XCTAssertThrowsError(try MASUserInput.parse("18446744073.709551616"))
        XCTAssertThrowsError(try MASUserInput.parse(""))
    }
    func testActualUITextFieldDelegateNormalizesSelectionAndRejectsWithoutReplacingOldAmount() throws {
        var value = "0.25", focused = false, rejected = false
        let component = AmountEntryField(text: Binding(get: { value }, set: { value = $0 }), isFocused: Binding(get: { focused }, set: { focused = $0 }), rejected: Binding(get: { rejected }, set: { rejected = $0 }))
        let delegate = component.makeCoordinator(), field = UITextField()
        field.text = value
        XCTAssertFalse(delegate.textField(field, shouldChangeCharactersIn: NSRange(location: 1, length: 1), replacementString: ","))
        XCTAssertEqual(field.text, "0.25"); XCTAssertEqual(value, "0.25"); XCTAssertFalse(rejected)
        let selection = try XCTUnwrap(field.selectedTextRange)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: selection.start), 2)
        XCTAssertFalse(delegate.textField(field, shouldChangeCharactersIn: NSRange(location: 4, length: 0), replacementString: ","))
        XCTAssertTrue(rejected); XCTAssertEqual(value, "0.25"); XCTAssertEqual(field.text, "0.25")
        XCTAssertFalse(delegate.textField(field, shouldChangeCharactersIn: NSRange(location: 0, length: 4), replacementString: "0,5"))
        XCTAssertFalse(rejected); XCTAssertEqual(value, "0.5")
        delegate.textFieldDidBeginEditing(field); XCTAssertTrue(focused)
        delegate.done(); XCTAssertFalse(focused)
    }
    func testInputCompositionCannotLeavePreviousAmountEligibleForReview() throws {
        var value = "1", focused = true, rejected = false
        let component = AmountEntryField(text: Binding(get: { value }, set: { value = $0 }), isFocused: Binding(get: { focused }, set: { focused = $0 }), rejected: Binding(get: { rejected }, set: { rejected = $0 }))
        let delegate = component.makeCoordinator(), field = ComposingAmountField()
        field.text = "1,25"
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        field.composing = true; XCTAssertNotNil(field.markedTextRange)
        delegate.editingChanged(field)
        XCTAssertTrue(rejected); XCTAssertEqual(value, "1")
        XCTAssertTrue(delegate.textField(field, shouldChangeCharactersIn: NSRange(location: 4, length: 0), replacementString: "0"))
        field.composing = false; delegate.editingChanged(field)
        XCTAssertFalse(rejected); XCTAssertEqual(value, "1.25")
    }
    func testPublicAddressCopyUsesFullValidatedIdentityAndClearsOnSelectionChange() throws {
        let first = try MassaTestAccount(seed: Data(repeating: 41, count: 32)).publicAccount.address
        let second = try MassaTestAccount(seed: Data(repeating: 42, count: 32)).publicAccount.address
        let state = PublicAddressCopyState(); var clipboard = ""
        XCTAssertTrue(state.copy(first, write: { clipboard = $0 })); XCTAssertEqual(clipboard, first)
        state.clear(); XCTAssertNil(state.copiedAddress)
        XCTAssertTrue(state.copy(second, write: { clipboard = $0 })); XCTAssertEqual(clipboard, second)
        XCTAssertFalse(state.copy("AU…truncated", write: { _ in XCTFail("Invalid address must not be copied") }))
        XCTAssertEqual(clipboard, second)
    }
    func testOwnerPolicyURLAndAllNewCopyAreLocalized() {
        XCTAssertEqual(PrivacyPolicyConfiguration.publishedURL?.absoluteString, "https://massive-x.com/privacy/")
        for language in AppLanguage.allCases where language != .english {
            for key in ["Enter the password you used when creating this YAML wallet file — not a new password.", "I have a backup of this wallet's private key.", "Back up private key", "Enter a valid amount with up to 9 decimal places."] {
                XCTAssertNotEqual(localized(key, language: language), key)
            }
        }
    }
}

@MainActor private final class PhoneUXStore: TestAccountSecretStore {
    var bytes: Data?
    func saveNew(_ seed: Data) throws { bytes = seed }
    func load(context: LAContext?) throws -> Data? { bytes }
    func delete() throws { XCTFail("Keyboard test must not delete anything") }
}
@MainActor private struct PhoneUXAuth: WalletAuthenticating {
    func authorize(reason: String) async throws -> LAContext { LAContext() }
    func cancel() {}
}
@MainActor private final class PhoneUXJournal: TransferJournal {
    let installationID: UUID? = UUID()
    func read() throws -> [PendingTransfer] { [] }
    func write(_ records: [PendingTransfer]) throws { XCTAssertTrue(records.isEmpty) }
}
private struct PhoneUXNoNetwork: MainnetReading, TransferNetworking, MainnetHistoryReading {
    func status() async throws -> MainnetStatus { XCTFail("No network allowed"); throw SendFailure.network }
    func balance(for address: String) async throws -> MainnetBalance { XCTFail("No network allowed"); throw SendFailure.network }
    func snapshot(source: String, recipient: String) async throws -> SendSnapshot { XCTFail("No network allowed"); throw SendFailure.network }
    func submit(_ draft: ReviewedTransfer, signature: String) async throws -> String { XCTFail("No submission allowed"); throw SendFailure.network }
    func lookup(operationID: String) async throws -> SubmissionState { XCTFail("No network allowed"); throw SendFailure.network }
    func page(address: String, cursor: HistoryCursor?) async throws -> HistoryPage { XCTFail("No network allowed"); throw SendFailure.network }
}
@MainActor extension FinalPhoneUXTests {
    func testRealSendViewKeepsKeyboardAfterEveryNormalizedKeystroke() async throws {
        let suite = "ux10-keyboard-" + UUID().uuidString, store = PhoneUXStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let wallets = WalletManager(defaults: defaults, stores: { _ in store }, authentication: { PhoneUXAuth() }, client: PhoneUXNoNetwork(), balanceChanged: { _, _ in }, walletsRemoved: { _ in })
        let added = await wallets.addOwned(active: true, captured: false); XCTAssertTrue(added)
        let send = SendCoordinator(network: PhoneUXNoNetwork(), journal: PhoneUXJournal())
        let root = SendView().environment(wallets).environment(send).environment(MainnetHistory(client: PhoneUXNoNetwork()))
            .environment(WalletState()).environment(AppLanguageSettings.shared)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene); window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible(); window.rootViewController?.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(150))
        func find(_ view: UIView) -> UITextField? {
            if let field = view as? UITextField, field.accessibilityIdentifier == "send.amount" { return field }
            return view.subviews.compactMap { find($0) }.first
        }
        let field = try XCTUnwrap(find(try XCTUnwrap(window.rootViewController?.view)))
        XCTAssertTrue(field.becomeFirstResponder())
        for character in ["0", ",", "2", "5"] {
            let accepted = field.delegate?.textField?(field, shouldChangeCharactersIn: NSRange(location: (field.text ?? "").utf16.count, length: 0), replacementString: character)
            XCTAssertEqual(accepted, false)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(field.isFirstResponder, "Typing must not dismiss the keyboard")
        }
        XCTAssertEqual(field.text, "0.25")
        let done = try XCTUnwrap((field.inputAccessoryView as? UIToolbar)?.items?.last)
        XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(done.action), to: done.target, from: done, for: nil))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(field.isFirstResponder, "Done must still dismiss the native keyboard")
    }
}
