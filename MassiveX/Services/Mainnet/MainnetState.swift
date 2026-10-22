import Foundation
import Observation

@MainActor @Observable final class MainnetState {
    enum Phase: Equatable { case idle, loading, connected(MainnetStatus), unavailable(String) }
    private(set) var phase = Phase.idle
    private let client: any MainnetReading
    init(client: any MainnetReading = MainnetRPC()) { self.client = client }
    func refresh() async {
        guard phase != .loading else { return }
        phase = .loading
        do { phase = .connected(try await client.status()) }
        catch { phase = .unavailable((error as? MainnetRPCError)?.userMessage ?? MainnetRPCError.offline.userMessage) }
    }
}
