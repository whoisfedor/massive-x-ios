import Foundation
import CryptoKit
import CommonCrypto

/// Deliberately bounded subset of the official single-account Version 1 YAML.
/// No object construction, tags, aliases, arbitrary KDF parameters or legacy secrets.
enum MassaYAMLImport {
    static let maximumBytes = 16_384
    enum Failure: Error { case format, version, authentication, identity, cancelled }
    struct Document: Sendable {
        let salt: Data
        let nonce: Data
        let ciphertext: Data
        let publicKey: Data
        let address: String?
    }
    static func parse(_ data: Data) throws -> Document {
        guard !data.isEmpty, data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw Failure.format }
        let allowed = Set(["Version", "Nickname", "Address", "Salt", "Nonce", "CipheredData", "PublicKey"])
        var fields: [String: String] = [:]
        var current: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("- "), let key = current, ["Salt", "Nonce", "CipheredData", "PublicKey"].contains(key) {
                let byte = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                guard UInt8(byte) != nil, byte.allSatisfy(\.isASCII), byte.allSatisfy(\.isNumber) else { throw Failure.format }
                fields[key, default: ""] += byte + ","
                continue
            }
            if let key = current, fields[key, default: ""].hasPrefix("["), !fields[key, default: ""].hasSuffix("]") {
                fields[key, default: ""] += line
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { throw Failure.format }
            let key = String(line[..<colon])
            guard allowed.contains(key), fields[key] == nil else { throw Failure.format }
            fields[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            current = key
        }
        guard let version = fields["Version"] else { throw Failure.format }
        guard version == "1" else { throw Failure.version }
        func scalar(_ key: String) throws -> String? {
            guard let raw = fields[key], !raw.isEmpty else { return nil }
            if raw.hasPrefix("\"") {
                guard let bytes = raw.data(using: .utf8), let value = try? JSONDecoder().decode(String.self, from: bytes) else { throw Failure.format }
                return value
            }
            if raw.hasPrefix("'") {
                guard raw.count >= 2, raw.hasSuffix("'") else { throw Failure.format }
                return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            guard !raw.contains(where: { "[]{}&*!|>#%".contains($0) }) else { throw Failure.format }
            return raw
        }
        _ = try scalar("Nickname") // Untrusted name is deliberately not used as wallet identity.
        func bytes(_ key: String, count: Int) throws -> Data {
            guard var raw = fields[key] else { throw Failure.format }
            if raw.hasPrefix("[") {
                guard raw.hasSuffix("]") else { throw Failure.format }
                raw = String(raw.dropFirst().dropLast())
            } else {
                guard raw.hasSuffix(",") else { throw Failure.format }
                raw.removeLast()
            }
            let values = raw.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard values.count == count else { throw Failure.format }
            var result = Data()
            for value in values {
                guard !value.isEmpty, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber), let byte = UInt8(value) else { throw Failure.format }
                result.append(byte)
            }
            return result
        }
        let publicKey = try bytes("PublicKey", count: 33)
        guard publicKey.first == 0 else { throw Failure.version }
        let address = try scalar("Address")
        if let address { guard (try? MassaPublicAccount.validateUserAddress(address)) != nil else { throw Failure.identity } }
        return try Document(salt: bytes("Salt", count: 16), nonce: bytes("Nonce", count: 12), ciphertext: bytes("CipheredData", count: 49), publicKey: publicKey, address: address)
    }
    /// Password and cleartext exist only within this call, never in Codable state or diagnostics.
    static func decrypt(_ document: Document, password: String) throws -> MassaTestAccount {
        guard !password.isEmpty, password.utf8.count <= 1024 else { throw Failure.authentication }
        try Task.checkCancellation()
        var passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        defer { _ = passwordBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }; _ = derived.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let status = passwordBytes.withUnsafeBytes { pass in
            document.salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.bindMemory(to: Int8.self).baseAddress, pass.count,
                    salt.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw Failure.authentication }
        try Task.checkCancellation()
        var clear: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: document.nonce), ciphertext: document.ciphertext.dropLast(16), tag: document.ciphertext.suffix(16))
            clear = try AES.GCM.open(box, using: SymmetricKey(data: derived))
        } catch { throw Failure.authentication }
        defer { clear.resetBytes(in: 0..<clear.count) }
        guard clear.count == 33, clear.first == 0 else { throw Failure.version }
        let account = try MassaTestAccount(seed: Data(clear.dropFirst()))
        let identity = try account.publicAccount
        guard Data([0]) + (try MassaCodec.decode(identity.publicKey, prefix: "P")) == document.publicKey,
              document.address == nil || document.address == identity.address else { throw Failure.identity }
        try Task.checkCancellation()
        return account
    }
}
