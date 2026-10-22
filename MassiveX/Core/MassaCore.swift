import CryptoKit
import Foundation

/// Strict v0 codecs, matching the pinned official SDK. No operation serialization or broadcasting.
enum MassaCoreError: Error { case invalidEncoding, invalidLength }

enum MassaCodec {
    static func hash(_ data: Data) -> Data {
        var result = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { input in mx_blake3(input.bindMemory(to: UInt8.self).baseAddress, data.count, &result) }
        return Data(result)
    }
    static func encode(_ bytes: Data, prefix: String) throws -> String {
        guard bytes.count == 32 || bytes.count == 64 else { throw MassaCoreError.invalidLength }
        var output = [CChar](repeating: 0, count: 101)
        var count = output.count
        let success = bytes.withUnsafeBytes { input in
            mx_base58check_encode(input.bindMemory(to: UInt8.self).baseAddress, bytes.count, &output, &count)
        }
        guard success else { throw MassaCoreError.invalidEncoding }
        return prefix + String(decoding: output.prefix(count - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    static func decode(_ string: String, prefix: String, length: Int = 32) throws -> Data {
        guard (length == 32 || length == 64), string.hasPrefix(prefix), string.utf8.count <= 102,
              string.unicodeScalars.allSatisfy({ $0.isASCII && $0.value != 0 }) else { throw MassaCoreError.invalidEncoding }
        let body = String(string.dropFirst(prefix.count))
        var output = [UInt8](repeating: 0, count: length)
        let valid = body.withCString { mx_base58check_decode($0, body.utf8.count, &output, length) }
        guard valid else { throw MassaCoreError.invalidEncoding }
        return Data(output)
    }
}

struct MassaPublicAccount: Equatable, Sendable {
    let publicKey: String
    let address: String
    init(rawPublicKey: Data) throws {
        guard rawPublicKey.count == 32 else { throw MassaCoreError.invalidLength }
        publicKey = try MassaCodec.encode(rawPublicKey, prefix: "P")
        // Massa hashes the VERSIONED public key, not the bare Ed25519 public key.
        address = try MassaCodec.encode(MassaCodec.hash(Data([0]) + rawPublicKey), prefix: "AU")
    }
    static func validateUserAddress(_ address: String) throws {
        _ = try MassaCodec.decode(address, prefix: "AU")
    }
    /// v0 account or contract address. This does not claim control of a contract account.
    static func validateAddress(_ address: String) throws {
        let prefix: String
        if address.hasPrefix("AU") { prefix = "AU" }
        else if address.hasPrefix("AS") { prefix = "AS" }
        else { throw MassaCoreError.invalidEncoding }
        _ = try MassaCodec.decode(address, prefix: prefix)
    }
    func verify(message: Data, signature: String) throws -> Bool {
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: MassaCodec.decode(publicKey, prefix: "P"))
        return key.isValidSignature(try MassaCodec.decode(signature, prefix: "", length: 64), for: MassaCodec.hash(message))
    }
}

/// Secret-bearing object. Never pass to UI state, logs, Codable, or assertion diagnostics.
final class MassaTestAccount: CustomStringConvertible, CustomDebugStringConvertible {
    private let key: Curve25519.Signing.PrivateKey
    var description: String { "MassaTestAccount(<redacted>)" }
    var debugDescription: String { description }
    init() { key = Curve25519.Signing.PrivateKey() }
    init(importing privateKey: String) throws {
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: MassaCodec.decode(privateKey, prefix: "S"))
    }
    init(seed: Data) throws {
        guard seed.count == 32 else { throw MassaCoreError.invalidLength }
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }
    var publicAccount: MassaPublicAccount {
        get throws { try MassaPublicAccount(rawPublicKey: key.publicKey.rawRepresentation) }
    }
    // Internal storage boundary, never exposed through a view model or network API.
    func storageData() -> Data { key.rawRepresentation }
    // Only the authenticated backup coordinator may expose this encoding to the UI.
    func backupPrivateKeyEncoding() throws -> String { try MassaCodec.encode(key.rawRepresentation, prefix: "S") }
    // Operation-only signing is called exclusively by the authenticated coordinator.
    func signOperation(_ content: Data, expected: MassaPublicAccount) throws -> String {
        guard try publicAccount == expected else { throw MassaCoreError.invalidEncoding }
        let canonical = try MassaOperationEncoding.canonical(content: content, publicKey: expected.publicKey)
        return try MassaCodec.encode(key.signature(for: MassaCodec.hash(canonical)), prefix: "")
    }
    #if DEBUG
    // Compatibility evidence only. Release omits signing helpers.
    func testPrivateKeyEncoding() throws -> String { try backupPrivateKeyEncoding() }
    func testSign(message: Data) throws -> String {
        try MassaCodec.encode(key.signature(for: MassaCodec.hash(message)), prefix: "")
    }
    #endif
}
