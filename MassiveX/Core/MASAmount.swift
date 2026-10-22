import Foundation

/// Exact MAS base units (SDK Mas.fromString uses 9 decimal places). No binary floating point.
struct MASAmount: Equatable, Comparable, Sendable, Codable {
    let nano: UInt64
    enum Invalid: Error { case format, overflow, zero, insufficientFunds, recipient }
    init(nano: UInt64) { self.nano = nano }
    init(_ text: String) throws {
        guard text.utf8.count <= 30,
              text.range(of: #"^(0|[1-9][0-9]*)(\.[0-9]{1,9})?\z"#, options: .regularExpression) != nil else { throw Invalid.format }
        let parts = text.split(separator: ".")
        guard let whole = UInt64(parts[0]) else { throw Invalid.overflow }
        let scaled = whole.multipliedReportingOverflow(by: 1_000_000_000)
        let fraction = parts.count == 2 ? UInt64(parts[1] + String(repeating: "0", count: 9 - parts[1].count))! : 0
        let total = scaled.partialValue.addingReportingOverflow(fraction)
        guard !scaled.overflow, !total.overflow else { throw Invalid.overflow }
        nano = total.partialValue
    }
    var text: String {
        let whole = nano / 1_000_000_000, fraction = nano % 1_000_000_000
        guard fraction != 0 else { return String(whole) }
        var digits = String(repeating: "0", count: 9 - String(fraction).count) + String(fraction)
        while digits.last == "0" { digits.removeLast() }
        return "\(whole).\(digits)"
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.nano < rhs.nano }
    static func validateTransfer(recipient: String, amount: String, fee: String, available: String) throws -> MASAmount {
        guard (try? MassaPublicAccount.validateAddress(recipient)) != nil else { throw Invalid.recipient }
        let amount = try Self(amount), fee = try Self(fee), available = try Self(available)
        guard amount.nano > 0 else { throw Invalid.zero }
        let debit = amount.nano.addingReportingOverflow(fee.nano)
        guard !debit.overflow, debit.partialValue <= available.nano else { throw Invalid.insufficientFunds }
        return Self(nano: debit.partialValue)
    }
}

/// Only for editable user input. RPC/journal decoding continues to require canonical dot decimals.
enum MASUserInput {
    static func parse(_ text: String) throws -> MASAmount {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        return try MASAmount(normalized.hasPrefix(".") ? "0" + normalized : normalized)
    }
    static func display(_ value: MASAmount, locale: Locale) -> String { value.text }

}

/// Conservative presentation only. Preflight and Max retain the original integer nano-MAS.
enum SendBalancePresentation {
    static func text(_ amount: MASAmount, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale; formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 0
        let whole = formatter.string(from: NSNumber(value: amount.nano / 1_000_000_000)) ?? String(amount.nano / 1_000_000_000)
        let milli = (amount.nano % 1_000_000_000) / 1_000_000
        guard milli != 0 else { return whole }
        var digits = String(repeating: "0", count: 3 - String(milli).count) + String(milli)
        while digits.last == "0" { digits.removeLast() }
        return whole + (locale.decimalSeparator ?? ".") + digits
    }
}
