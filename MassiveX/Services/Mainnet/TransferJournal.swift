import Foundation
import Darwin

enum TransferJournalError: Error, Equatable {
    case unavailable, missing, corrupt, capacity, inconsistent
    static func classify(_ error: any Error) -> Self { (error as? Self) ?? .unavailable }
    var message: String {
        switch self {
        case .unavailable: L("Protected transfer storage is unavailable. Unlock the device and retry storage recovery. No replacement transaction will be submitted.")
        case .missing: L("The previous transfer journal is missing. Restore the original journal or seek trusted support. Sending is locked to preserve unknown outcomes.")
        case .corrupt, .inconsistent: L("Transfer records failed integrity checks. Preserve the original journal and seek trusted support; do not delete it to unlock sending.")
        case .capacity: L("Transfer journal capacity reached. No new submission is allowed. Preserve the records and seek a reviewed storage migration; existing operations can still be checked.")
        }
    }
}
enum TransferJournalPolicy {
    static let maximumRecords = 10_000
    static func validate(_ records: [PendingTransfer]) throws {
        guard records.count <= maximumRecords else { throw TransferJournalError.capacity }
        guard Set(records.map { $0.draft.operationID }).count == records.count else { throw TransferJournalError.corrupt }
        // Migration/restoration may retain several unresolved intents for one source. Every ID is
        // kept; the coordinator forbids any NEW intent while any of them remains unresolved.
        do {
            for record in records {
                try record.draft.validate()
                if record.assessment?.providerResolution != nil || record.assessment?.historicalResolution != nil {
                    guard record.hasTrustedResolution else { throw TransferJournalError.corrupt }
                }
                if let assessment = record.assessment {
                    guard assessment.state == record.state, (assessment.observations?.count ?? 0) <= 16,
                          (assessment.terminalClaims ?? []).allSatisfy({ $0 == .finalized || $0 == .failed }) else { throw TransferJournalError.corrupt }
                }
            }
        } catch { throw TransferJournalError.corrupt }
    }
}
/// No compaction: terminal IDs still protect against duplicate intents; unresolved records are never discarded.
/// A separate existence anchor detects loss of a journal previously observed by this installation.
@MainActor final class FileTransferJournal: TransferJournal {
    private struct Envelope: Codable {
        let version: Int
        let installationID: UUID
        let records: [PendingTransfer]
    }
    private(set) var installationID: UUID?
    private let initialIdentity: UUID
    private let url: URL
    private let marker: URL
    private let defaults: UserDefaults?
    private let replace: (Data, URL) throws -> Void
    init(url: URL? = nil, initialIdentity: UUID = UUID(), replace: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: [.atomic, .completeFileProtection]) }) {
        self.initialIdentity = initialIdentity
        self.url = url ?? URL.applicationSupportDirectory.appending(path: "MainnetTransfers/pending-v1.json")
        marker = self.url.appendingPathExtension("initialized")
        defaults = url == nil ? .standard : nil
        self.replace = replace
    }
    private var expectedKey: String { "mainnet.transfer-journal.initialized.v1" }
    private func markerExists() throws -> Bool {
        do {
            guard try Data(contentsOf: marker) == Data([1]) else { throw TransferJournalError.corrupt }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return defaults?.bool(forKey: expectedKey) ?? false }
        catch let error as TransferJournalError { throw error }
        catch { throw TransferJournalError.unavailable }
    }
    private func markInitialized() throws {
        if !FileManager.default.fileExists(atPath: marker.path) {
            try replace(Data([1]), marker); try protect(marker); try flush(marker)
        } else { _ = try markerExists() }
        defaults?.set(true, forKey: expectedKey)
    }
    func read() throws -> [PendingTransfer] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            if try markerExists() { throw TransferJournalError.missing }
            installationID = initialIdentity
            return [] // No surviving evidence, NOT proof of clean history for imported identities.
        } catch { throw TransferJournalError.unavailable }
        guard data.count <= 33_554_432 else { throw TransferJournalError.corrupt }
        let values: [PendingTransfer]
        do {
            if data.first(where: { ![UInt8(9), 10, 13, 32].contains($0) }) == 91 {
                values = try JSONDecoder().decode([PendingTransfer].self, from: data)
                installationID = installationID ?? initialIdentity // Legacy array; identity becomes durable on validated write.
            } else {
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.version == 2 else { throw TransferJournalError.corrupt }
                values = envelope.records; installationID = envelope.installationID
            }
        } catch { throw TransferJournalError.corrupt }
        try TransferJournalPolicy.validate(values)
        do { try markInitialized() } catch let error as TransferJournalError { throw error } catch { throw TransferJournalError.unavailable }
        return values
    }
    func write(_ records: [PendingTransfer]) throws {
        try TransferJournalPolicy.validate(records) // Before encoding/replacement, never after a network submission.
        if !FileManager.default.fileExists(atPath: url.path), try markerExists() { throw TransferJournalError.missing }
        if installationID == nil {
            if FileManager.default.fileExists(atPath: url.path) { _ = try read() }
            else { installationID = initialIdentity }
        }
        guard let installationID else { throw TransferJournalError.unavailable }
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            var resource = URLResourceValues(); resource.isExcludedFromBackup = true
            var folder = parent; try folder.setResourceValues(resource)
            let data = try JSONEncoder().encode(Envelope(version: 2, installationID: installationID, records: records))
            guard data.count <= 33_554_432 else { throw TransferJournalError.capacity }
            try replace(data, url); try protect(url); try flush(url); try markInitialized()
        } catch let error as TransferJournalError { throw error } catch { throw TransferJournalError.unavailable }
    }
    private func protect(_ file: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
    }
    private func flush(_ file: URL) throws {
        for path in [file.path, file.deletingLastPathComponent().path] {
            let descriptor = open(path, O_RDONLY)
            guard descriptor >= 0 else { throw TransferJournalError.unavailable }
            let result = fsync(descriptor); close(descriptor)
            guard result == 0 else { throw TransferJournalError.unavailable }
        }
    }
}
