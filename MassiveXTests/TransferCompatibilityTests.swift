import XCTest
@testable import MassiveX

final class TransferCompatibilityTests: XCTestCase {
    func testThreeOfficialOfflineTransferFixtures() throws {
        struct Fixtures: Decodable { let vectors: [Vector] }
        struct Vector: Decodable { let fee: String; let amount: String; let expirePeriod: UInt64; let recipient: String; let publicKey: String; let serialized: String; let canonical: String; let signature: String }
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(Self.fixtures.utf8))
        let publicFixtures = try JSONSerialization.jsonObject(with: Data(PublicMassaFixtures.json.utf8)) as! [String: Any]
        let vector = (publicFixtures["vectors"] as! [[String: Any]])[0]
        let key = try MassaTestAccount(importing: vector["privateKey"] as! String)
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        var evidence = [[String: String]]()
        for fixture in fixtures.vectors {
            let content = try MassaTransferCompatibility.serialized(fee: MASAmount(fixture.fee), amount: MASAmount(fixture.amount), expirePeriod: fixture.expirePeriod, recipient: fixture.recipient)
            XCTAssertEqual(hex(content), fixture.serialized)
            let canonical = try MassaTransferCompatibility.canonical(content: content, publicKey: fixture.publicKey)
            XCTAssertEqual(hex(canonical), fixture.canonical)
            // CryptoKit signatures need not be byte-identical to the SDK signer.
            let native = try key.testSign(message: canonical)
            XCTAssertTrue(try key.publicAccount.verify(message: canonical, signature: native))
            evidence.append(["canonical": hex(canonical), "publicKey": fixture.publicKey, "signature": native])
            let publicAccount = try key.publicAccount
            XCTAssertTrue(try publicAccount.verify(message: canonical, signature: fixture.signature))
            XCTAssertFalse(try publicAccount.verify(message: canonical + Data([1]), signature: fixture.signature))
        }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // PUBLIC known-insecure vector signatures only, never key material.
        try JSONEncoder().encode(evidence).write(to: directory.appendingPathComponent("public-native-transfer-signatures.json"))
    }
    private static let fixtures = #"""
{
  "sdk": "5.4.0",
  "revision": "d48c0db559ff35e84b38c481a447345b540e22b7",
  "warning": "PUBLIC TEST ONLY. No network or spendable wallet.",
  "vectors": [
    {
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
      "fee": "1",
      "amount": "18446744072.709551615",
      "expirePeriod": 987654321,
      "recipient": "AU12MBEEKVAFZhxYzeyNYpAAcKEu667KKjHBos9i65htLwPkHyQG4",
      "publicKey": "P1TAfk4W8xsRPnfJGZwRznpZq8MxzdCEGv65UFx3RnNbft1hwLg",
      "serialized": "8094ebdc03b1d1f9d603000000b1824b170cc25c8d8dbc6ac5e89e5ec7ec9063db8ea89bb3232c720594373f58ffeb94a3fcffffffff01",
      "canonical": "0000000004a0f909003b6a27bcceb6a42d62a3a8d02a6f0d73653215771de243a63ac048a18b59da298094ebdc03b1d1f9d603000000b1824b170cc25c8d8dbc6ac5e89e5ec7ec9063db8ea89bb3232c720594373f58ffeb94a3fcffffffff01",
      "signature": "1NWk1uuzkTY1tPYFk6VspZTd93hPtvy7wbpSJ27aWJ5pPofCqAwbWpHvehxrScTAu9FxoTjM9rn2hAuwWepoNH5Ahr6yZ3"
    }
  ]
}
"""#
}
