import Foundation

/// Public, unsigned data only. V0 Transaction encoding/ID per pinned SDK and MAIN.5.0/MAIN.5.1.
/// No key retrieval, signature creation, RPC write or automatic retry is exposed here.
enum MassaOperationEncoding {
    static func serialized(fee: MASAmount, amount: MASAmount, expirePeriod: UInt64, recipient: String) throws -> Data {
        try MassaPublicAccount.validateAddress(recipient)
        let type: UInt8 = recipient.hasPrefix("AU") ? 0 : 1
        return varint(fee.nano) + varint(expirePeriod) + Data([0, type, 0])
            + (try MassaCodec.decode(recipient, prefix: type == 0 ? "AU" : "AS")) + varint(amount.nano)
    }
    static func canonical(content: Data, publicKey: String) throws -> Data {
        var chain = MassaEnvironment.mainnet.chainID.bigEndian
        let network = withUnsafeBytes(of: &chain) { Data($0) }
        return network + Data([0]) + (try MassaCodec.decode(publicKey, prefix: "P")) + content
    }
    static func operationID(content: Data, publicKey: String) throws -> String {
        try MassaCodec.encode(MassaCodec.hash(canonical(content: content, publicKey: publicKey)), prefix: "O")
    }
    private static func varint(_ value: UInt64) -> Data {
        var value = value, result = Data()
        repeat {
            var byte = UInt8(value & 127); value >>= 7
            if value != 0 { byte |= 128 }
            result.append(byte)
        } while value != 0
        return result
    }
}
