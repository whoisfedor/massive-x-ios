import Observation

@Observable final class WalletState {
    var balanceHidden = false
    var showsFiat = false
    func toggleUnit() { showsFiat.toggle() }
    func toggleBalance() { balanceHidden.toggle() }
}
