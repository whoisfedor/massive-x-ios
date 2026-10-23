import SwiftUI

/// Native edit-range normalization: comma → dot is one UTF-16 unit, so the caret never jumps to the end.
/// A single comma means a decimal separator, never grouping. Wire/RPC parsing is unchanged.
enum AmountTextEdit {
    struct Result: Equatable { let text: String; let caret: Int }
    static func apply(_ text: String, range: NSRange, replacement: String) -> Result? {
        guard let swiftRange = Range(range, in: text) else { return nil }
        let value = text.replacingCharacters(in: swiftRange, with: replacement).replacingOccurrences(of: ",", with: ".")
        guard value.utf8.count <= 30,
              value.range(of: #"^[0-9]*(\.[0-9]{0,9})?\z"#, options: .regularExpression) != nil else { return nil }
        return Result(text: value, caret: range.location + replacement.utf16.count)
    }
}
struct AmountEntryField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var rejected: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.placeholder = "0"; field.keyboardType = .decimalPad
        field.autocorrectionType = .no; field.textContentType = nil
        field.font = UIFont.monospacedDigitSystemFont(ofSize: 34, weight: .medium)
        field.adjustsFontForContentSizeCategory = true
        field.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: field.font!)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.accessibilityIdentifier = "send.amount"
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        let toolbar = UIToolbar(); toolbar.sizeToFit()
        toolbar.items = [.flexibleSpace(), UIBarButtonItem(title: L("Done"), style: .done, target: context.coordinator, action: #selector(Coordinator.done))]
        field.inputAccessoryView = toolbar
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self; context.coordinator.field = field
        if field.markedTextRange == nil, field.text != text { field.text = text }
        field.accessibilityLabel = L("MAS amount")
        field.tintColor = UIColor(Theme.accent)
        (field.inputAccessoryView as? UIToolbar)?.items?.last?.title = L("Done")
        // UIKit keyboard ownership is native; external focus changes dismiss it without re-entering SwiftUI updates.
        if !isFocused, field.isFirstResponder { field.resignFirstResponder() }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AmountEntryField
        weak var field: UITextField?
        init(_ parent: AmountEntryField) { self.parent = parent }
        @objc func done() { field?.resignFirstResponder(); parent.isFocused = false }
        func textFieldDidBeginEditing(_ textField: UITextField) { field = textField; parent.isFocused = true }
        func textFieldDidEndEditing(_ textField: UITextField) { parent.isFocused = false }
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            // Do not rewrite an active input-method composition. Validate at commit instead.
            if textField.markedTextRange != nil { parent.rejected = true; return true }
            guard let result = AmountTextEdit.apply(textField.text ?? "", range: range, replacement: string) else {
                parent.rejected = true; return false
            }
            commit(result, to: textField)
            return false
        }
        private func commit(_ result: AmountTextEdit.Result, to textField: UITextField) {
            textField.text = result.text
            if let position = textField.position(from: textField.beginningOfDocument, offset: result.caret) {
                textField.selectedTextRange = textField.textRange(from: position, to: position)
            }
            parent.rejected = false; parent.text = result.text
        }
        @objc func editingChanged(_ textField: UITextField) {
            guard textField.markedTextRange == nil else { parent.rejected = true; return }
            let raw = textField.text ?? ""
            let caret = textField.selectedTextRange.map { textField.offset(from: textField.beginningOfDocument, to: $0.start) } ?? raw.utf16.count
            if let normalized = AmountTextEdit.apply("", range: NSRange(location: 0, length: 0), replacement: raw) {
                commit(.init(text: normalized.text, caret: caret), to: textField)
            } else { textField.text = parent.text; parent.rejected = true }
        }
    }
}

/// Stable native ownership for wallet-form fields. Ordinary labels/addresses are never secure
/// inputs; private keys and encrypted-backup passwords retain native secure-entry protection.
struct WalletInputField: UIViewRepresentable {
    enum Role: Equatable { case name, address, privateKey, backupPassword
        var secure: Bool { self == .privateKey || self == .backupPassword }
    }
    let title: String
    @Binding var text: String
    @Binding var isFocused: Bool
    let role: Role
    let identifier: String
    var next = false
    var eraseContent = false
    var onSubmit: @MainActor () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        let toolbar = UIToolbar(); toolbar.sizeToFit()
        toolbar.items = [.flexibleSpace(), UIBarButtonItem(title: L("Done"), style: .done, target: context.coordinator, action: #selector(Coordinator.done))]
        field.inputAccessoryView = toolbar
        context.coordinator.field = field
        configure(field)
        return field
    }
    private func configure(_ field: UITextField) {
        // Do not toggle secure entry on normal re-renders: that can reset selection and keyboard state.
        if field.isSecureTextEntry != role.secure { field.isSecureTextEntry = role.secure }
        // Empty semantic content type requests no credential association; never mislabel as an OTP.
        field.textContentType = UITextContentType(rawValue: "")
        field.passwordRules = nil
        field.autocapitalizationType = role == .name ? .words : .none
        field.autocorrectionType = role == .name ? .default : .no
        field.spellCheckingType = role == .name ? .default : .no
        field.smartQuotesType = .no; field.smartDashesType = .no; field.smartInsertDeleteType = .no
        field.keyboardType = role == .address || role == .privateKey ? .asciiCapable : .default
        field.returnKeyType = next ? .next : .done
        field.placeholder = title; field.accessibilityIdentifier = identifier; field.accessibilityLabel = title
        if role.secure { field.accessibilityValue = L("Hidden from accessibility output") }
        field.tintColor = UIColor(Theme.accent)
        (field.inputAccessoryView as? UIToolbar)?.items?.last?.title = L("Done")
    }
    func updateUIView(_ field: UITextField, context: Context) {
        if context.coordinator.configuredRole != role {
            field.text = ""; configure(field); context.coordinator.configuredRole = role
        }
        context.coordinator.parent = self; context.coordinator.field = field
        field.placeholder = title; field.accessibilityLabel = title; field.tintColor = UIColor(Theme.accent)
        (field.inputAccessoryView as? UIToolbar)?.items?.last?.title = L("Done")
        // Explicit privacy erasure wins over composition. An empty model alone must not erase
        // an unfinished first character before an input method commits it.
        if role.secure && eraseContent { field.text = "" }
        else if field.markedTextRange == nil, field.text != text { field.text = text }
        if !isFocused, field.isFirstResponder { field.resignFirstResponder() }
        if isFocused, !field.isFirstResponder {
            // Defer only programmatic focus, not editing: re-check current ownership before activating.
            Task { @MainActor [weak field, weak coordinator = context.coordinator] in
                guard let field, let coordinator, coordinator.parent.isFocused,
                      field.window != nil, !field.isFirstResponder else { return }
                field.becomeFirstResponder()
            }
        }
    }
    static func dismantleUIView(_ field: UITextField, coordinator: Coordinator) {
        field.resignFirstResponder(); field.text = ""; field.delegate = nil; coordinator.field = nil
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: WalletInputField
        var configuredRole: Role
        weak var field: UITextField?
        init(_ parent: WalletInputField) { self.parent = parent; configuredRole = parent.role }
        func textFieldDidBeginEditing(_ textField: UITextField) { parent.isFocused = true }
        func textFieldDidEndEditing(_ textField: UITextField) { parent.isFocused = false }
        @objc func changed(_ textField: UITextField) {
            if parent.role.secure && parent.eraseContent { textField.text = ""; parent.text = ""; return }
            guard textField.markedTextRange == nil else { return }
            parent.text = textField.text ?? ""
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            done(); parent.onSubmit(); return false
        }
        @objc func done() { field?.resignFirstResponder(); parent.isFocused = false }
    }
}
