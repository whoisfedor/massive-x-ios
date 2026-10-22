import XCTest
@testable import MassiveX

final class OperationIDTests: XCTestCase {
    func testFourIndependentSDKAndCoreFormulaOperationIDs() throws {
        struct Vector: Decodable { let signature: String; let operationID: String; let fee: String; let amount: String; let expirePeriod: UInt64; let recipient: String; let publicKey: String }
        struct Fixture: Decodable { let vectors: [Vector] }
        let fixtures = try JSONDecoder().decode(Fixture.self, from: Data(Self.fixtures.utf8))
        XCTAssertEqual(fixtures.vectors.count, 4)
        for vector in fixtures.vectors {
            let content = try MassaOperationEncoding.serialized(fee: MASAmount(vector.fee), amount: MASAmount(vector.amount), expirePeriod: vector.expirePeriod, recipient: vector.recipient)
            let account = try MassaPublicAccount(rawPublicKey: MassaCodec.decode(vector.publicKey, prefix: "P"))
            XCTAssertTrue(try account.verify(message: MassaOperationEncoding.canonical(content: content, publicKey: vector.publicKey), signature: vector.signature))
            XCTAssertEqual(try MassaOperationEncoding.operationID(content: content, publicKey: vector.publicKey), vector.operationID)
            XCTAssertNotEqual(try MassaOperationEncoding.operationID(content: content + Data([1]), publicKey: vector.publicKey), vector.operationID)
            XCTAssertThrowsError(try MassaOperationEncoding.operationID(content: content, publicKey: "Pbad"))
        }
    }
    func testASRecipientValidationRetainsExactAmountAndFeeChecks() throws {
        let contract = try MassaCodec.encode(Data(repeating: 7, count: 32), prefix: "AS")
        XCTAssertEqual(try MASAmount.validateTransfer(recipient: contract, amount: "1.000000001", fee: "0.01", available: "1.010000001").text, "1.010000001")
        XCTAssertThrowsError(try MASAmount.validateTransfer(recipient: contract, amount: "1.000000001", fee: "0.01", available: "1.01"))
        XCTAssertThrowsError(try MASAmount.validateTransfer(recipient: contract, amount: "0", fee: "0.01", available: "1"))
    }
    @MainActor func testSpecificSendAvailabilityDoesNotInferKeyAccessibility() throws {
        let identity = try MassaTestAccount().publicAccount
        var wallet = ManagedWallet(id: UUID().uuidString, name: "Disposable", address: identity.address, publicKey: identity.publicKey, kind: .owned, network: "Mainnet", backupAcknowledged: false)
        XCTAssertEqual(SendAvailability.evaluate(wallet), .available)
        XCTAssertEqual(SendAvailability.evaluate(nil), .noWallet)
        wallet.safety = .archivedPreview
        XCTAssertEqual(SendAvailability.evaluate(wallet), .archived)
        let watch = ManagedWallet(id: UUID().uuidString, name: "Watch", address: identity.address, publicKey: nil, kind: .watchOnly, network: "Mainnet", backupAcknowledged: false)
        XCTAssertEqual(SendAvailability.evaluate(watch), .watchOnly)
        let invalid = ManagedWallet(id: UUID().uuidString, name: "Invalid", address: identity.address, publicKey: nil, kind: .owned, network: "Mainnet", backupAcknowledged: false)
        XCTAssertEqual(SendAvailability.evaluate(invalid), .invalidIdentity)
    }
    private static let fixtures = #"""
{
  "sdk": "5.4.0",
  "revision": "d48c0db559ff35e84b38c481a447345b540e22b7",
  "warning": "PUBLIC TEST ONLY. No network or spendable wallet.",
  "vectors": [
    {
      "operationID": "O128C3ggxK9PdqSU97cReQpqEFFm8xTPG9v5xeeTmgbeXVNtJaFe",
      "fee": "0.01",
      "amount": "3.123456789",
      "expirePeriod": 5336156,
      "recipient": "AU12MBEEKVAFZhxYzeyNYpAAcKEu667KKjHBos9i65htLwPkHyQG4",
      "publicKey": "P1TAfk4W8xsRPnfJGZwRznpZq8MxzdCEGv65UFx3RnNbft1hwLg",
      "serialized": "80ade204dcd8c502000000b1824b170cc25c8d8dbc6ac5e89e5ec7ec9063db8ea89bb3232c720594373f5895d6b0d10b",
      "canonical": "0000000004a0f909003b6a27bcceb6a42d62a3a8d02a6f0d73653215771de243a63ac048a18b59da2980ade204dcd8c502000000b1824b170cc25c8d8dbc6ac5e89e5ec7ec9063db8ea89bb3232c720594373f5895d6b0d10b",
      "signature": "15MCTAmQ8e1Q4VMUgJv7UbZPFH1vPpcr2w1Vm1LvGXtJayrTcdmQAcVi6rcgtF4HFY5ntZeapHw13R5W2qPALpfoxa2mTE"
    },
    {
      "operationID": "O1EVWib7XGxgt5D7jEJMGnXXbzxc5QahGwW8ibLcjgCuVGqUuHQ",
      "fee": "0.000000001",
      "amount": "0.000000001",
      "expirePeriod": 1,
      "recipient": "AU12MBEEKVAFZhxYzeyNYpAAcKEu667KKjHBos9i65htLwPkHyQG4",
      "publicKey": "P1TAfk4W8xsRPnfJGZwRznpZq8MxzdCEGv65UFx3RnNbft1hwLg",
      "serialized": "0101000000b1824b170cc25c8d8dbc6ac5e89e5ec7ec9063db8ea89bb3232c720594373f5801",
      "canonical": "0000000004a0f909003b6a27bcceb6a42d62a3a8d02a6f0d73653215771de243a63ac048a18b59da290101000000b1824b170cc25c8d8dbc6ac5e89e5ec7ec9063db8ea89bb3232c720594373f5801",
      "signature": "1HsqeHuJXK4jnUg9cjAFteSVqVm1AoaGRU7kdY58ZnUw5YY9zCckpqzZBVgxzUhGvvVZo5YD4ZPgq2uRcqBZy9QwjYfXee"
    },
    {
      "operationID": "O12XbvsPt11L33toimi1s1sx2RLtigq9ehd1Y6KRGrLB2y6M3VT1",
      "fee": "1",
      "amount": "18446744072.709551615",
      "expirePeriod": 987654321,
      "recipient": "AU12MBEEKVAFZhxYzeyNYpAAcKEu667KKjHBos9i65htLwPkHyQG4",
      "publicKey": "P1TAfk4W8xsRPnfJGZwRznpZq8MxzdCEGv65UFx3RnNbft1hwLg",
      "serialized": "8094ebdc03b1d1f9d603000000b1824b170cc25c8d8dbc6ac5e89e5ec7ec9063db8ea89bb3232c720594373f58ffeb94a3fcffffffff01",
      "canonical": "0000000004a0f909003b6a27bcceb6a42d62a3a8d02a6f0d73653215771de243a63ac048a18b59da298094ebdc03b1d1f9d603000000b1824b170cc25c8d8dbc6ac5e89e5ec7ec9063db8ea89bb3232c720594373f58ffeb94a3fcffffffff01",
      "signature": "1NWk1uuzkTY1tPYFk6VspZTd93hPtvy7wbpSJ27aWJ5pPofCqAwbWpHvehxrScTAu9FxoTjM9rn2hAuwWepoNH5Ahr6yZ3"
    },
    {
      "operationID": "O1suGPCtvGnf8DgAeMVWFtiHj9GK79Cfy4r8x5DCMsMNCqi3gRQ",
      "fee": "0.01",
      "amount": "1",
      "expirePeriod": 5336156,
      "recipient": "AS12MBEEKVAFZhxYzeyNYpAAcKEu667KKjHBos9i65htLwPkHyQG4",
      "publicKey": "P1TAfk4W8xsRPnfJGZwRznpZq8MxzdCEGv65UFx3RnNbft1hwLg",
      "serialized": "80ade204dcd8c502000100b1824b170cc25c8d8dbc6ac5e89e5ec7ec9063db8ea89bb3232c720594373f588094ebdc03",
      "canonical": "0000000004a0f909003b6a27bcceb6a42d62a3a8d02a6f0d73653215771de243a63ac048a18b59da2980ade204dcd8c502000100b1824b170cc25c8d8dbc6ac5e89e5ec7ec9063db8ea89bb3232c720594373f588094ebdc03",
      "signature": "121dvakjz1quJ6nxmwyfty2nEzfFHafsX1syJM3fxuZnKkjERrsHMBbZHhXuHHsTSLBDgxnNrzSmAdZoNfJwqrk5bJDk2T"
    }
  ]
}
"""#
}
