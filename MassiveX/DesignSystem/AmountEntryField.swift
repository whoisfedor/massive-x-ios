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
