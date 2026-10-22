import CryptoKit
import XCTest
@testable import MassiveX

final class MassaCoreTests: XCTestCase {
    struct Fixtures: Decodable {
        let vectors: [Vector]
        let malformed: [Malformed]
        struct Malformed: Decodable { let name: String; let value: String }
    }
    struct Vector: Decodable {
        let pattern: String
        let seedHex: String
        let privateKey: String
        let publicKey: String
        let publicKeyHex: String
        let address: String
        let addressHashHex: String
        let messageHex: String
        let signature: String
        let signatureHex: String
    }
    private func fixtures() throws -> Fixtures { try JSONDecoder().decode(Fixtures.self, from: Data(PublicMassaFixtures.json.utf8)) }
    private func data(_ hex: String) -> Data {
        let chars = Array(hex)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! })
    }
    func testOfficialSDKPrivatePublicAndExactAddressVectors() throws {
        for vector in try fixtures().vectors {
            let account = try MassaTestAccount(seed: data(vector.seedHex))
            // Booleans intentionally prevent XCTest from printing key material on failure.
            XCTAssertTrue(try account.testPrivateKeyEncoding() == vector.privateKey, "Private encoding mismatch for public fixture")
            let imported = try MassaTestAccount(importing: vector.privateKey)
            let publicAccount = try account.publicAccount
            XCTAssertTrue(try imported.publicAccount == publicAccount)
            XCTAssertTrue(publicAccount.publicKey == vector.publicKey)
            XCTAssertTrue(publicAccount.address == vector.address)
            XCTAssertTrue(try MassaCodec.decode(publicAccount.publicKey, prefix: "P") == data(vector.publicKeyHex))
            XCTAssertTrue(try MassaCodec.decode(publicAccount.address, prefix: "AU") == data(vector.addressHashHex))
            XCTAssertNoThrow(try MassaPublicAccount.validateUserAddress(publicAccount.address))
        }
    }
    func testOfficialSDKSignaturesAndTampering() throws {
        var evidence = [[String: String]]()
        for vector in try fixtures().vectors {
            let account = try MassaTestAccount(importing: vector.privateKey)
            let message = data(vector.messageHex)
            // CryptoKit randomizes Ed25519 signatures; verify rather than compare bytes.
            let nativeSignature = try account.testSign(message: message)
            XCTAssertTrue(try account.publicAccount.verify(message: message, signature: nativeSignature))
            evidence.append(["pattern": vector.pattern, "signature": nativeSignature])
            XCTAssertTrue(try account.publicAccount.verify(message: message, signature: vector.signature))
            XCTAssertFalse(try account.publicAccount.verify(message: message + Data([1]), signature: vector.signature))
            XCTAssertTrue(try MassaCodec.decode(vector.signature, prefix: "", length: 64) == data(vector.signatureHex))
        }
        // Only signatures from public, known-insecure fixtures leave the test process.
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try JSONEncoder().encode(evidence).write(to: directory.appendingPathComponent("public-native-signatures.json"))
    }
    func testSecureRandomGenerationAndStorageRoundTripWithoutLoggingSecrets() throws {
        let first = MassaTestAccount()
        let second = MassaTestAccount()
        XCTAssertTrue(first.storageData().count == 32)
        XCTAssertTrue(first.storageData() != second.storageData())
        let restored = try MassaTestAccount(seed: first.storageData())
        XCTAssertTrue(try restored.publicAccount == first.publicAccount)
        let encoded = try first.testPrivateKeyEncoding()
        XCTAssertTrue(try MassaTestAccount(importing: encoded).publicAccount == first.publicAccount)
        XCTAssertTrue(String(describing: first).contains("redacted"))
    }
    func testRejectsMalformedKeysVersionsLengthsAndChecksums() throws {
        let fixture = try fixtures()
        let valid = fixture.vectors[1].privateKey
        let badChecksum = String(valid.dropLast()) + (valid.last == "1" ? "2" : "1")
        for input in ["", "S0OIl", "P" + valid.dropFirst(), " " + valid, valid + "\n", valid + "\0", String(repeating: "1", count: 1000), badChecksum] + fixture.malformed.map(\.value) {
            var rejected = false
            do { _ = try MassaTestAccount(importing: input) } catch { rejected = true }
            XCTAssertTrue(rejected, "Malformed input was accepted")
        }
        XCTAssertThrowsError(try MassaTestAccount(seed: Data(repeating: 0, count: 31)))
        XCTAssertThrowsError(try MassaTestAccount(seed: Data(repeating: 0, count: 33)))
    }
    func testRejectsWrongAddressTypeAndCorruption() throws {
        let address = try fixtures().vectors[0].address
        for input in ["AS" + address.dropFirst(2), "AU0", address + "1", String(address.dropLast()) + "0"] {
            XCTAssertThrowsError(try MassaPublicAccount.validateUserAddress(input))
        }
    }
    func testOfficialBlake3EmptyVector() {
        XCTAssertTrue(MassaCodec.hash(Data()) == data("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"))
    }
}
