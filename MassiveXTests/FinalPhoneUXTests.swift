import XCTest
import SwiftUI
import UIKit
import LocalAuthentication
import CoreText
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
    func testActivityMeasuredBaselinePlacementPreservesHitAreaAndWrappedRows() {
        for scale: CGFloat in [1, 1.5, 2.5, 3.5] {
            for includesStatus in [false, true] {
                let text = OperationTextColumns.Cell(size: CGSize(width: 110, height: 15 * scale), firstBaseline: 11 * scale, lastBaseline: 11 * scale)
                let hitHeight = max(44, text.size.height)
                let hitBaseline = (hitHeight - text.size.height) / 2 + text.lastBaseline
                let cells = [
                    OperationTextColumns.Cell(size: CGSize(width: 130, height: 18 * scale), firstBaseline: 14 * scale, lastBaseline: 14 * scale),
                    .init(size: CGSize(width: 80, height: 20 * scale), firstBaseline: 15 * scale, lastBaseline: 15 * scale),
                    .init(size: CGSize(width: 110, height: hitHeight), firstBaseline: hitBaseline, lastBaseline: hitBaseline),
                    .init(size: CGSize(width: 170, height: 30 * scale), firstBaseline: 11 * scale, lastBaseline: 26 * scale)
                ] + (includesStatus ? [.init(size: CGSize(width: 110, height: 15 * scale), firstBaseline: 11 * scale, lastBaseline: 11 * scale)] : [])
                let result = OperationTextColumns.arrange(width: 306, cells: cells, addressText: text)
                XCTAssertEqual(result.origins[0].y + cells[0].firstBaseline, result.origins[1].y + cells[1].firstBaseline, accuracy: 0.001)
                XCTAssertEqual(result.origins[2].y + cells[2].lastBaseline, result.origins[3].y + cells[3].lastBaseline, accuracy: 0.001)
                let visibleAddressTop = result.origins[2].y + cells[2].lastBaseline - text.lastBaseline
                XCTAssertGreaterThanOrEqual(visibleAddressTop, result.origins[0].y + cells[0].size.height + 4)
                XCTAssertEqual(result.contentFrame.minY, result.size.height - result.contentFrame.maxY, accuracy: 0.001, "Equal top/bottom text-group margins")
                let priorHeight = max(18 * scale + 1 * scale, 20 * scale) + 4 + (includesStatus ? 15 * scale + 4 : 0) + 15 * scale + hitHeight
                XCTAssertEqual(result.size.height, priorHeight, accuracy: 0.001, "Keep the existing row budget")
                for index in cells.indices {
                    XCTAssertGreaterThanOrEqual(result.origins[index].y, 0)
                    XCTAssertLessThanOrEqual(result.origins[index].y + cells[index].size.height, result.size.height)
                }
                XCTAssertGreaterThanOrEqual(cells[2].size.height, 44)
            }
        }
    }

    func testActivityStatusAndMissingCounterpartyRowsRenderWithoutClipping() throws {
        let suite = "activity-status-layout-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let language = AppLanguageSettings(defaults: defaults)
        let source = try MassaCodec.encode(Data(repeating: 42, count: 32), prefix: "AU")
        for size in [DynamicTypeSize.large, .accessibility5] {
            for (status, succeeded) in [("Speculative", Optional<Bool>.none), ("Final", false), ("Final", Optional<Bool>.none)] {
                let operation = MainnetOperation(id: "synthetic-status-layout", type: "ExecuteSC", sender: source, recipient: nil,
                    amount: nil, fee: nil, date: Date(timeIntervalSince1970: 1_792_500_000), status: status, executionSucceeded: succeeded)
                let row = OperationRow(operation: operation, address: source).environment(language).environment(WalletState())
                    .environment(\.dynamicTypeSize, size).frame(width: 350).fixedSize(horizontal: false, vertical: true)
                let image = try XCTUnwrap(ImageRenderer(content: row).cgImage)
                XCTAssertGreaterThan(image.height, 44)
                XCTAssertEqual(image.width, 350)
            }
        }
    }

    func testActivityTextBaselinesAcrossKindsLocalesAppearancesAndDynamicType() throws {
        let suite = "activity-baselines-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let language = AppLanguageSettings(defaults: defaults)
        let previousLanguage = UserDefaults.standard.object(forKey: "app.language")
        defer {
            if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: "app.language") }
            else { UserDefaults.standard.removeObject(forKey: "app.language") }
        }
        let source = try MassaCodec.encode(Data(repeating: 42, count: 32), prefix: "AU")
        let other = try MassaCodec.encode(Data(repeating: 43, count: 32), prefix: "AU")
        var normalImages: [CGImage] = [], accessibilityImages: [CGImage] = []
        var spacingEvidence: [[String: String]] = []
        for selected in AppLanguage.allCases {
            language.select(selected)
            UserDefaults.standard.set(selected.rawValue, forKey: "app.language")
            for size in [DynamicTypeSize.large, .accessibility1, .accessibility5] {
                for dark in [true, false] {
                    for (type, sender, recipient) in [("Transaction", source, other), ("Transaction", other, source), ("CallSC", source, other)] {
                        let operation = MainnetOperation(id: "synthetic-layout-only", type: type, sender: sender, recipient: recipient,
                            amount: MASAmount(nano: 1_000_000_000), fee: nil, date: Date(timeIntervalSince1970: 1_792_500_000), status: "Final", executionSucceeded: true)
                        let row = OperationRow(operation: operation, address: source)
                            .environment(language).environment(WalletState())
                            .environment(\.locale, selected.locale).environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.dynamicTypeSize, size)
                            .foregroundStyle(dark ? Color.white : Color.black)
                            .frame(width: 350).fixedSize(horizontal: false, vertical: true)
                            .background(dark ? Color.black : Color.white)
                        let renderer = ImageRenderer(content: row); renderer.scale = 2
                        let image = try XCTUnwrap(renderer.cgImage)
                        if selected == .english && size == .large { normalImages.append(image) }
                        if selected == .russian && size == .accessibility5 { accessibilityImages.append(image) }
                        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                        let background = dark ? 0 : 255
                        func bands(_ columns: Range<Int>) -> [ClosedRange<Int>] {
                            var result: [ClosedRange<Int>] = []
                            for y in 0..<image.height {
                                let hasInk = columns.contains { x in
                                    let offset = (y * image.width + x) * 4
                                    return (0..<3).contains { abs(Int(pixels[offset + $0]) - background) > 50 }
                                }
                                if hasInk {
                                    if let last = result.last, y - last.upperBound <= 5 { result[result.count - 1] = last.lowerBound...y }
                                    else { result.append(y...y) }
                                }
                            }
                            return result
                        }
                        let left = bands(90..<180), right = bands(620..<700)
                        let contextLabel = "\(selected.rawValue), \(size), \(dark), \(type)"
                        XCTAssertGreaterThanOrEqual(left.count, 2, contextLabel)
                        XCTAssertGreaterThanOrEqual(right.count, 2, contextLabel)
                        let textPixels = bands(88..<700)
                        if let top = textPixels.first?.lowerBound, let bottom = textPixels.last?.upperBound {
                            let below = image.height - bottom - 1
                            XCTAssertLessThanOrEqual(abs(top - below), size == .large ? 8 : 24, "Center the whole visible two-column group: " + contextLabel)
                            spacingEvidence.append(["case": contextLabel, "rowHeightPixels": String(image.height), "topInkMarginPixels": String(top), "bottomInkMarginPixels": String(below)])
                        }
                        // Corresponding text baselines remain shared; ink may include descenders.
                        let tolerance = size == .large ? 6 : 18
                        if let addressBand = left.last, let dateBand = right.last {
                            XCTAssertLessThanOrEqual(abs(addressBand.upperBound - dateBand.upperBound), tolerance, "Address/date baseline: " + contextLabel)
                            XCTAssertLessThan(addressBand.upperBound, image.height - 6, "Address must not clip: " + contextLabel)
                        }
                        if size == .large, let titleBand = left.first, let amountBand = right.first {
                            // Compare raster baselines after subtracting real glyph descenders (e.g. French ç).
                            func inkDescent(_ text: String, font: UIFont) -> CGFloat {
                                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]) as CFAttributedString)
                                return max(0, -CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).minY)
                            }
                            let titleFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
                            let titleString = operation.title(for: source)
                            let titleLine = CTLineCreateWithAttributedString(NSAttributedString(string: titleString, attributes: [.font: titleFont]) as CFAttributedString)
                            let visibleEnd = CTLineGetStringIndexForPosition(titleLine, CGPoint(x: 46, y: 0))
                            let visibleTitle = (titleString as NSString).substring(to: min((titleString as NSString).length, max(0, visibleEnd) + 1))
                            let titleDescent = inkDescent(visibleTitle, font: titleFont) * 2
                            let titleBaseline = CGFloat(titleBand.upperBound) - titleDescent
                            XCTAssertLessThanOrEqual(abs(titleBaseline - CGFloat(amountBand.upperBound)), 3, "Title/amount baseline: " + contextLabel)
                            let otherText = try XCTUnwrap(operation.shortCounterparty(for: source))
                            let dateText = HistoryListPresentation.timestamp(operation.date, locale: selected.locale, timeZone: .current)
                            let addressDescent = inkDescent(otherText, font: .monospacedSystemFont(ofSize: 12, weight: .regular)) * 2
                            // The right raster strip contains the time suffix, not the earlier date comma.
                            let dateDescent = inkDescent(String(dateText.suffix(5)), font: .systemFont(ofSize: 12)) * 2
                            if let addressBand = left.last, let dateBand = right.last {
                                XCTAssertLessThanOrEqual(abs(CGFloat(addressBand.upperBound) - addressDescent - CGFloat(dateBand.upperBound) + dateDescent), 4, "Normal address/date raster baseline: " + contextLabel)
                            }
                            if left.count == 2 {
                                XCTAssertLessThanOrEqual(left[1].lowerBound - left[0].upperBound, 22, "Keep compact title/address spacing: " + contextLabel)
                            }
                            XCTAssertLessThanOrEqual(image.height, 220, "Only natural two-line localized-title height: " + contextLabel)
                        }
                    }
                }
            }
        }
        let measurements = XCTAttachment(data: try JSONSerialization.data(withJSONObject: spacingEvidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        measurements.name = "Activity-centering-measurements"; measurements.lifetime = .keepAlways; add(measurements)
        // Two targeted contact sheets, not a screenshot batch or owner data.
        for (name, images) in [("Activity-normal", normalImages), ("Activity-accessibility-Russian", accessibilityImages)] {
            let width = try XCTUnwrap(images.first).width
            let height = images.reduce(0) { $0 + $1.height }
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            var top = height
            for image in images {
                top -= image.height
                context.draw(image, in: CGRect(x: 0, y: top, width: image.width, height: image.height))
            }
            let attachment = XCTAttachment(image: UIImage(cgImage: try XCTUnwrap(context.makeImage())))
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

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

@MainActor extension FinalPhoneUXTests {
    func testActualWalletFormsKeepTraitsFocusAndSingleNativeDoneAcrossRenders() async throws {
        let suite = "wallet-input-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let wallets = WalletManager(defaults: defaults, stores: { _ in PhoneUXStore() }, authentication: { PhoneUXAuth() },
            client: PhoneUXNoNetwork(), balanceChanged: { _, _ in }, walletsRemoved: { _ in })
        let language = AppLanguageSettings(defaults: defaults)
        let send = SendCoordinator(network: PhoneUXNoNetwork(), journal: PhoneUXJournal())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func fields(_ view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        for (mode, expected) in [(AddWalletView.Mode.newWallet, ["wallet.name": false]),
                                  (.privateKey, ["wallet.name": false, "wallet.private-key": true]),
                                  (.watchOnly, ["wallet.name": false, "wallet.address": false]),
                                  (.yaml, ["yaml.name": false, "yaml.password": true])] {
            func root(_ phase: ScenePhase) -> some View {
                NavigationStack { AddWalletView(initialMode: mode) }.environment(wallets).environment(send).environment(language)
                    .environment(\.scenePhase, phase)
            }
            let host = UIHostingController(rootView: root(.active))
            window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            for (identifier, secure) in expected {
                let field = try XCTUnwrap(fields(host.view).first { $0.accessibilityIdentifier == identifier })
                XCTAssertEqual(field.isSecureTextEntry, secure, identifier)
                XCTAssertEqual(field.textContentType?.rawValue, "", identifier)
                XCTAssertNil(field.passwordRules)
                if secure { XCTAssertEqual(field.accessibilityValue, L("Hidden from accessibility output")) }
                XCTAssertTrue(field.becomeFirstResponder())
                for value in ["d", "du", "dummy-input"] {
                    field.text = value; field.sendActions(for: .editingChanged)
                    try await Task.sleep(for: .milliseconds(30))
                    XCTAssertTrue(field.isFirstResponder, identifier)
                    XCTAssertEqual(field.text, value)
                    XCTAssertTrue(fields(host.view).contains { $0 === field }, "No field recreation on editing")
                }
                language.select(.french); try await Task.sleep(for: .milliseconds(30))
                XCTAssertTrue(field.isFirstResponder); XCTAssertTrue(fields(host.view).contains { $0 === field })
                host.rootView = root(.inactive); try await Task.sleep(for: .milliseconds(40))
                XCTAssertTrue(fields(host.view).contains { $0 === field }, "Transient inactivity must not remove the field")
                XCTAssertTrue(field.isFirstResponder)
                host.rootView = root(.active); try await Task.sleep(for: .milliseconds(40))
                let toolbar = try XCTUnwrap(field.inputAccessoryView as? UIToolbar)
                XCTAssertEqual(toolbar.items?.filter { $0.action != nil }.count, 1)
                let done = try XCTUnwrap(toolbar.items?.last)
                XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(done.action), to: done.target, from: done, for: nil))
                XCTAssertFalse(field.isFirstResponder)
                XCTAssertEqual(field.isSecureTextEntry, secure)
                host.rootView = root(.background); try await Task.sleep(for: .milliseconds(40))
                XCTAssertFalse(field.isFirstResponder)
                if secure { XCTAssertEqual(field.text, "", "Background must clear secret inputs") }
                host.rootView = root(.active); try await Task.sleep(for: .milliseconds(40))
            }
            // Reconstruct the form with new native controls; no secure traits may leak across modes.
            window.rootViewController = nil
        }
    }
    func testNativeWalletInputPasteUsesInjectedProvidersAndReturnAdvancesFocus() async throws {
        let suite = "wallet-paste-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let wallets = WalletManager(defaults: defaults, stores: { _ in PhoneUXStore() }, authentication: { PhoneUXAuth() },
            client: PhoneUXNoNetwork(), balanceChanged: { _, _ in }, walletsRemoved: { _ in })
        let language = AppLanguageSettings(defaults: defaults)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let root = NavigationStack { AddWalletView(initialMode: .yaml) }.environment(wallets)
            .environment(SendCoordinator(network: PhoneUXNoNetwork(), journal: PhoneUXJournal())).environment(language)
            .environment(\.scenePhase, .active).environment(\.isSceneCaptured, false)
        let host = UIHostingController(rootView: root); window.rootViewController = host
        window.makeKeyAndVisible(); host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(150))
        func find(_ view: UIView, _ identifier: String) -> UITextField? {
            if let field = view as? UITextField, field.accessibilityIdentifier == identifier { return field }
            return view.subviews.compactMap { find($0, identifier) }.first
        }
        let name = try XCTUnwrap(find(host.view, "yaml.name")), password = try XCTUnwrap(find(host.view, "yaml.password"))
        XCTAssertTrue(name.becomeFirstResponder())
        XCTAssertEqual(name.delegate?.textFieldShouldReturn?(name), false)
        for _ in 0..<40 { if password.isFirstResponder { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(password.isFirstResponder)
        // If the system exposes marked composition in secure entry, a model that is still
        // empty must not wipe the first composed character during an unrelated redraw.
        password.setMarkedText("я", selectedRange: NSRange(location: 1, length: 0))
        if password.markedTextRange != nil {
            language.select(.french); try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(password.text, "я")
        }
        password.unmarkText(); password.text = ""; password.sendActions(for: .editingChanged)
        // UIKit's native item-provider paste path; never touches the owner's general clipboard.
        password.paste(itemProviders: [NSItemProvider(object: "  dummy-backup-password  " as NSString)])
        for _ in 0..<40 { if password.text == "  dummy-backup-password  " { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(password.text, "  dummy-backup-password  "); XCTAssertTrue(password.isSecureTextEntry)
        XCTAssertEqual(password.delegate?.textFieldShouldReturn?(password), false)
        XCTAssertFalse(password.isFirstResponder)
        XCTAssertFalse(WalletImportPresentation.validKey("dummy-backup-password"))
    }
    func testNewRecoveryAndInputCopyExistsInAllSixLanguages() throws {
        for language in AppLanguage.allCases {
            let bundle = try XCTUnwrap(Bundle(path: XCTUnwrap(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"))))
            for key in ["New transfer", "Not yet confirmed by Massa Mainnet RPC.", "Copy text before pasting.", "Paste password"] {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "MISSING", table: nil), "MISSING")
            }
        }
    }
}
