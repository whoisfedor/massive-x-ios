#if DEBUG
import Foundation

/// Compatibility shim for the existing public-vector tests. Signing is still DEBUG-only.
enum MassaTransferCompatibility {
    static func serialized(fee: MASAmount, amount: MASAmount, expirePeriod: UInt64, recipient: String) throws -> Data {
        try MassaOperationEncoding.serialized(fee: fee, amount: amount, expirePeriod: expirePeriod, recipient: recipient)
    }
    static func canonical(content: Data, publicKey: String) throws -> Data {
        try MassaOperationEncoding.canonical(content: content, publicKey: publicKey)
    }
}
#endif
