import XCTest
@testable import MassiveX

final class MassiveXTests: XCTestCase {
    func testBalanceVisibility() {
        let state = WalletState()
        XCTAssertFalse(state.balanceHidden)
        state.toggleBalance(); XCTAssertTrue(state.balanceHidden)
        state.toggleBalance(); XCTAssertFalse(state.balanceHidden)
    }
    func testExactAmountsAndTransferValidation() throws {
        XCTAssertEqual(try MASAmount("0.000000001").nano, 1)
        XCTAssertEqual(try MASAmount("18446744073.709551615").nano, UInt64.max)
        XCTAssertEqual(MASAmount(nano: 1_234_567_890).text, "1.23456789")
        XCTAssertEqual(MASAmount(nano: 0).text, "0")
        for invalid in ["-1", "+1", "1,5", "NaN", "1e3", "1.", "01", ".1", "1\n", "1.0000000001", "18446744073.709551616"] {
            XCTAssertThrowsError(try MASAmount(invalid))
        }
        let address = try MassaTestAccount(seed: Data(repeating: 0, count: 32)).publicAccount.address
        XCTAssertEqual(try MASAmount.validateTransfer(recipient: address, amount: "1.25", fee: "0.01", available: "1.26").nano, 1_260_000_000)
        for amount in ["0", "-1", "1.2500000001", "1.26"] {
            XCTAssertThrowsError(try MASAmount.validateTransfer(recipient: address, amount: amount, fee: "0.01", available: "1.26"))
        }
        XCTAssertThrowsError(try MASAmount.validateTransfer(recipient: "invalid", amount: "1", fee: "0.01", available: "2"))
    }
}
