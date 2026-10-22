import SwiftUI

struct FiatCurrencyView: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    @Environment(FiatSettings.self) private var fiat
    @Environment(FiatPrices.self) private var prices
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        let _ = liveLanguage.language
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search currency or code"), text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel(L("Clear search")) }
            }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 20).padding(.vertical, 8)
            List {
                Section {
                    ForEach(FiatCurrency.matching(search)) { currency in
                        Button { fiat.select(currency.id); dismiss() } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(currency.id).font(.headline)
                                    Text(currency.name).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if fiat.currency == currency.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }.foregroundStyle(.primary).frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.listRowBackground(Theme.surface)
            }.scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively)
            DisclosureGroup(L("Quote details")) {
                VStack(alignment: .leading, spacing: 8) {
                    if let quote = prices.quotes[fiat.currency] {
                        Text(quote.source + " · " + localizedDate(quote.priceUpdated)).font(.caption)
                        if !quote.usable(at: Date()) || prices.errors.contains(fiat.currency) { Text(L("Cached estimate · Latest refresh failed")).foregroundStyle(Theme.warning) }
                    } else { Text(L("Fiat value unavailable")) }
                    if prices.errors.contains(fiat.currency) { Text(L("Quote refresh failed. Check your connection or try again later.")).foregroundStyle(Theme.warning) }
                    if prices.cooldown.contains(fiat.currency) { Text(L("Please wait a moment before refreshing again.")) }
                    if let fetched = prices.fetchedAt[fiat.currency] { Text(L("Last successful read") + ": " + localizedDate(fetched)).font(.caption) }
                    Button { Task { await prices.refresh(fiat.currency, force: true) } } label: {
                        HStack { if prices.loading.contains(fiat.currency) { ProgressView() }; Label(L("Refresh quote"), systemImage: "arrow.clockwise") }
                    }.disabled(prices.loading.contains(fiat.currency))
                    Text(L("Crypto estimates use fresh MAS/USD and coin/USD quotes from CoinGecko. Other currencies may use Frankfurter reference FX. Estimates are not guaranteed execution prices.")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(16).background(Theme.surface).font(.subheadline)
        }.background(Theme.background).navigationTitle(L("Currency")).navigationBarTitleDisplayMode(.inline)
            .task(id: fiat.currency) { await prices.refresh(fiat.currency) }
    }
}
