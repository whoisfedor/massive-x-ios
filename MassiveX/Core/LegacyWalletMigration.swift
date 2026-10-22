import Foundation

/// Historical storage identifiers only, never a network configuration or fallback.
/// They cannot be renamed without losing access to preserved preview keys.
@MainActor enum LegacyWalletMigration {
    static let catalogKey = "buildnet.wallet-catalog.v1"
    static let singleRecordKey = "buildnet.public-wallet-record.v1"
    static let legacyID = "legacy-test-wallet-v1"
    static let account = "buildnet-test-account"
    static func service(_ id: String) -> String {
        id == legacyID ? "com.massivex.buildnet.test-wallet.v1" : "com.massivex.buildnet.wallet." + id
    }
    static func load(_ defaults: UserDefaults) throws -> [ManagedWallet] {
        struct OldCatalog: Decodable { let wallets: [ManagedWallet] }
        if let data = defaults.data(forKey: catalogKey) {
            return try JSONDecoder().decode(OldCatalog.self, from: data).wallets.map { item in
                var item = item; item.safety = .archivedPreview; item.storage = .legacy; item.network = "Archived preview"
                return item
            }
        }
        if let data = defaults.data(forKey: singleRecordKey) {
            let record = try JSONDecoder().decode(WalletRecord.self, from: data).validated()
            return [ManagedWallet(id: legacyID, name: "Archived wallet", address: record.address, publicKey: record.publicKey,
                kind: .owned, network: "Archived preview", backupAcknowledged: record.backupAcknowledged,
                safety: .archivedPreview, storage: .legacy)]
        }
        return []
    }
}

/// Public known-insecure SDK vectors. Never offer their addresses as fundable accounts.
enum KnownUnsafeWallets {
    static let addresses: Set<String> = [
        "AU1rqxSMewKgJU2m5orM2HFuMg7ioEFiECuhX1sSken92VxUBfQy",
        "AU12MBEEKVAFZhxYzeyNYpAAcKEu667KKjHBos9i65htLwPkHyQG4",
        "AU12b9KwUq6tSJ1hG2EdLrysd9LWEhshwNp514hAJ2RskT4kc7voi",
        "AU1FgfkVQ5nVCHdw9n4Rt6Lq9EULgicGPTWLNzM5NxD6g8TrJVyi",
    ]
}
