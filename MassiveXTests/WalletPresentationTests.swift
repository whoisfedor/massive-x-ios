import XCTest
@testable import MassiveX

private let quoteTestNow = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!
private actor PriceTransport: RPCTransport {
    enum Mode { case success, stale, missingTimestamp, negative, wrongAsset, wrongFX, oldFX, offline }
    let mode: Mode
    var urls: [URL] = []
    init(_ mode: Mode = .success) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> RPCTransportResponse {
        let url = request.url!; urls.append(url)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertFalse(url.absoluteString.contains("AU"))
        if mode == .offline { throw URLError(.notConnectedToInternet) }
        let body: String
        if url.path.hasSuffix("supported_vs_currencies") {
            body = #"["usd","eur"]"#
        } else if url.host == "api.coingecko.com" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "ids" }?.value, "massa")
            let timestamp = Int(quoteTestNow.timeIntervalSince1970) - (mode == .stale ? 1000 : 0)
            let asset = mode == .wrongAsset ? "other-asset" : "massa"
            let rate = mode == .negative ? "-0.01" : "0.01"
            let time = mode == .missingTimestamp ? "" : ",\"last_updated_at\":\(timestamp)"
            body = "{\"\(asset)\":{\"usd\":\(rate),\"eur\":0.009\(time)}}"
        } else {
            XCTAssertEqual(url.host, "api.frankfurter.dev")
            let currency = mode == .wrongFX ? "JPY" : "ISK"
            let date = mode == .oldFX ? "2026-10-01" : "2026-10-19"
            body = "{\"date\":\"\(date)\",\"base\":\"USD\",\"quote\":\"\(currency)\",\"rate\":125.5}"
        }
        return RPCTransportResponse(data: Data(body.utf8), statusCode: 200)
    }
}
private actor FixedPrice: MassaPriceProviding {
    var calls = 0
    let failed: Bool
    init(failed: Bool = false) { self.failed = failed }
    func quote(currency: String, now: Date) async throws -> FiatQuote {
        calls += 1
        if failed { throw FiatPriceError.unavailable }
        return FiatQuote(currency: currency, perMAS: 2, priceUpdated: now, fxDate: nil)
    }
}

final class WalletPresentationTests: XCTestCase {
    func testDisplayRoundsToTwoDigitsWithoutChangingExactAmount() throws {
        let value = try MASAmount("1666.266365086"), locale = Locale(identifier: "en_US")
        XCTAssertEqual(WalletAmountDisplay.mas(value, locale: locale), "1,666.27")
        XCTAssertEqual(value.nano, 1_666_266_365_086)
        XCTAssertEqual(value.text, "1666.266365086")
        XCTAssertEqual(WalletAmountDisplay.mas(try MASAmount("0.000000001"), locale: locale), "0.00")
        XCTAssertEqual(WalletAmountDisplay.mas(value, locale: Locale(identifier: "de_DE")), "1.666,27")
    }
    @MainActor func testUnitToggleAndPrivacyHideMASAndFiat() throws {
        let value = try MASAmount("12.345678901"), state = WalletState()
        let quote = FiatQuote(currency: "USD", perMAS: 2, priceUpdated: quoteTestNow, fxDate: nil)
        let locale = Locale(identifier: "en_US")
        func display() -> String { WalletAmountDisplay.summary(value, showFiat: state.showsFiat, hidden: state.balanceHidden, quote: quote, currency: "USD", now: quoteTestNow, locale: locale) }
        XCTAssertEqual(display(), "12.35")
        state.toggleUnit(); XCTAssertEqual(display(), "$ 24.69")
        state.toggleBalance(); XCTAssertEqual(display(), "••••••")
        state.toggleUnit(); XCTAssertEqual(display(), "••••••")
        state.toggleBalance(); XCTAssertEqual(display(), "12.35")
        XCTAssertEqual(value.nano, 12_345_678_901)
    }
    func testFiatUnavailableAndStaleOrWrongCurrencyNeverMasqueradesAsQuote() throws {
        let value = try MASAmount("1")
        let stale = FiatQuote(currency: "USD", perMAS: 1, priceUpdated: quoteTestNow.addingTimeInterval(-901), fxDate: nil)
        let mismatch = FiatQuote(currency: "EUR", perMAS: 1, priceUpdated: quoteTestNow, fxDate: nil)
        for quote in [nil, stale, mismatch] {
            XCTAssertEqual(WalletAmountDisplay.fiat(value, quote: quote, currency: "USD", now: quoteTestNow), "Fiat value unavailable")
        }
        XCTAssertEqual(WalletAmountDisplay.fiat(nil, quote: mismatch, currency: "EUR", now: quoteTestNow), "Fiat value unavailable")
    }
    @MainActor func testCurrencyCoverageSearchAndPersistenceAreIndependent() {
        let suite = "fiat-settings." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("darkCrimson", forKey: "accentPalette"); defaults.set("Dark", forKey: "appearance")
        let settings = FiatSettings(defaults: defaults)
        XCTAssertEqual(settings.currency, "USD")
        XCTAssertGreaterThan(FiatCurrency.all.count, 100)
        XCTAssertTrue(FiatCurrency.matching("yen").contains { $0.id == "JPY" })
        settings.select("JPY"); XCTAssertEqual(FiatSettings(defaults: defaults).currency, "JPY")
        settings.select("invalid"); XCTAssertEqual(settings.currency, "JPY")
        XCTAssertEqual(defaults.string(forKey: "accentPalette"), "darkCrimson")
        XCTAssertEqual(defaults.string(forKey: "appearance"), "Dark")
    }
    func testVerifiedAssetDirectQuotesAndSupportedCurrencyCache() async throws {
        let transport = PriceTransport(), provider = PublicMassaPriceProvider(transport: transport)
        let usd = try await provider.quote(currency: "USD", now: quoteTestNow)
        let eur = try await provider.quote(currency: "EUR", now: quoteTestNow)
        XCTAssertEqual(usd.perMAS, Decimal(string: "0.01")); XCTAssertEqual(eur.perMAS, Decimal(string: "0.009"))
        XCTAssertNil(usd.fxDate); XCTAssertEqual(usd.source, "CoinGecko")
        let urls = await transport.urls
        XCTAssertEqual(urls.filter { $0.path.hasSuffix("supported_vs_currencies") }.count, 1)
        XCTAssertFalse(urls.contains { $0.host == "api.frankfurter.dev" })
    }
    func testUnsupportedMarketCurrencyUsesVerifiedUSDAndFX() async throws {
        let transport = PriceTransport(), provider = PublicMassaPriceProvider(transport: transport)
        let quote = try await provider.quote(currency: "ISK", now: quoteTestNow)
        XCTAssertEqual(quote.perMAS, Decimal(string: "1.255"))
        XCTAssertEqual(quote.currency, "ISK"); XCTAssertNotNil(quote.fxDate)
        XCTAssertEqual(quote.source, "CoinGecko + Frankfurter")
    }
    func testMalformedMissingStaleAndOfflinePricesFailClosed() async {
        for mode: PriceTransport.Mode in [.stale, .missingTimestamp, .negative, .wrongAsset, .wrongFX, .oldFX, .offline] {
            do {
                _ = try await PublicMassaPriceProvider(transport: PriceTransport(mode)).quote(currency: "ISK", now: quoteTestNow)
                XCTFail("Untrusted quote must not be accepted")
            } catch {}
        }
    }
    @MainActor func testQuoteCacheThrottlesAndCurrencyMismatchDoesNotReuseOldValue() async {
        let provider = FixedPrice(), store = FiatPrices(provider: provider)
        await store.refresh("USD", now: quoteTestNow)
        await store.refresh("USD", now: quoteTestNow.addingTimeInterval(30))
        let count = await provider.calls; XCTAssertEqual(count, 1)
        XCTAssertNotNil(store.quote("USD", now: quoteTestNow))
        XCTAssertNil(store.quote("EUR", now: quoteTestNow))
        XCTAssertNil(store.quote("USD", now: quoteTestNow.addingTimeInterval(901)))
        let failed = FiatPrices(provider: FixedPrice(failed: true))
        await failed.refresh("USD", now: quoteTestNow)
        XCTAssertNil(failed.quote("USD", now: quoteTestNow)); XCTAssertTrue(failed.errors.contains("USD"))
    }
    @MainActor func testOrangePersistenceAndNeutralSurfacesPreserveOriginalPalettes() {
        let suite = "orange-theme." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let settings = ThemeSettings(defaults: prefs); settings.select(.orange)
        XCTAssertEqual(ThemeSettings(defaults: prefs).palette, .orange)
        for dark in [false, true] {
            let orange = AccentPalette.orange.tokens(dark: dark), blue = AccentPalette.midnightBlue.tokens(dark: dark)
            XCTAssertEqual(orange.background, blue.background); XCTAssertEqual(orange.surface, blue.surface)
            XCTAssertNotEqual(orange.accent, blue.accent)
        }
        XCTAssertEqual(AccentPalette.midnightBlue.tokens(dark: true).accent, PaletteRGB(0.43, 0.66, 1))
        XCTAssertEqual(AccentPalette.darkCrimson.tokens(dark: true).background, PaletteRGB(0.055, 0.027, 0.037))
    }
}

private actor DelayedBalances: MainnetReading {
    var requests = 0
    var pending: CheckedContinuation<MainnetBalance, Never>?
    var firstAddress: String?
    func status() async throws -> MainnetStatus { MainnetStatus(version: "TEST", chainID: 77_658_377, currentCycle: 1) }
    func balance(for address: String) async throws -> MainnetBalance {
        requests += 1
        if requests == 1 {
            firstAddress = address
            return await withCheckedContinuation { pending = $0 }
        }
        return MainnetBalance(address: address, finalBalance: "2", candidateBalance: "2")
    }
    func releaseFirst() {
        pending?.resume(returning: MainnetBalance(address: firstAddress!, finalBalance: "1", candidateBalance: "1")); pending = nil
    }
}
extension WalletPresentationTests {
    @MainActor func testWalletSwitchCannotExposePriorWalletBalanceDuringOutOfOrderRefresh() async throws {
        let suite = "wallet-switch-ui." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let rpc = DelayedBalances(), manager = WalletManager(defaults: prefs, client: rpc)
        XCTAssertTrue(manager.addWatchOnly(address: try MassaTestAccount().publicAccount.address, name: "First"))
        let firstID = try XCTUnwrap(manager.selectedID)
        let first = Task { await manager.refreshBalance(firstID) }
        while await rpc.requests == 0 { await Task.yield() }
        XCTAssertTrue(manager.addWatchOnly(address: try MassaTestAccount().publicAccount.address, name: "Second"))
        let secondID = try XCTUnwrap(manager.selectedID)
        XCTAssertNil(manager.balances[secondID])
        await manager.refreshBalance(secondID)
        await rpc.releaseFirst(); await first.value
        XCTAssertTrue(manager.selectedID == secondID)
        XCTAssertEqual(manager.balances[manager.selectedID!]?.finalBalance, "2")
        XCTAssertEqual(manager.balances[firstID]?.finalBalance, "1")
        XCTAssertNil(manager.backup)
    }
}

private actor CryptoQuoteTransport: RPCTransport {
    enum Mode { case success, missing, stale, mismatchedTime, zero, offline }
    let mode: Mode
    var requests = 0
    init(_ mode: Mode = .success) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> RPCTransportResponse {
        requests += 1
        XCTAssertEqual(request.httpMethod, "GET")
        let url = request.url!
        XCTAssertEqual(url.host, "api.coingecko.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "vs_currencies" }?.value, "usd")
        XCTAssertEqual(items.first { $0.name == "precision" }?.value, "full")
        let asset = items.first { $0.name == "ids" }!.value!.split(separator: ",")[1]
        if mode == .offline { throw URLError(.notConnectedToInternet) }
        let time = Int(quoteTestNow.timeIntervalSince1970) - (mode == .stale ? 1000 : 0)
        let coinTime = time - (mode == .mismatchedTime ? 400 : 0)
        let divisor = mode == .zero ? "0" : asset == "bitcoin" ? "100000" : asset == "ethereum" ? "2000" : "100"
        let coin = mode == .missing ? "" : ",\"\(asset)\":{\"usd\":\(divisor),\"last_updated_at\":\(coinTime)}"
        return RPCTransportResponse(data: Data("{\"massa\":{\"usd\":0.5,\"last_updated_at\":\(time)}\(coin)}".utf8), statusCode: 200)
    }
}
private actor RefreshQuoteMock: MassaPriceProviding {
    var calls = 0
    var fail = false
    func setFailed() { fail = true }
    func quote(currency: String, now: Date) async throws -> FiatQuote {
        calls += 1
        await Task.yield()
        if fail { throw FiatPriceError.unavailable }
        return FiatQuote(currency: currency, perMAS: Decimal(calls), priceUpdated: now, fxDate: nil)
    }
}
extension WalletPresentationTests {
    func testCryptoSameSourceCrossRatesAndExactDisplay() async throws {
        let transport = CryptoQuoteTransport(), provider = PublicMassaPriceProvider(transport: transport)
        let rates: [String: String] = ["BTC":"0.000005", "ETH":"0.00025", "SOL":"0.005"]
        for (code, expected) in rates {
            let quote = try await provider.quote(currency: code, now: quoteTestNow)
            XCTAssertEqual(quote.perMAS, Decimal(string: expected))
            let text = WalletAmountDisplay.fiat(try MASAmount("1"), quote: quote, currency: code, now: quoteTestNow, locale: Locale(identifier: "en_US"))
            XCTAssertEqual(text, expected + " " + code); XCTAssertFalse(text.contains("$"))
        }
        let requests = await transport.requests; XCTAssertEqual(requests, 3)
        let tiny = FiatQuote(currency: "BTC", perMAS: Decimal(string: "0.0000000000001")!, priceUpdated: quoteTestNow, fxDate: nil)
        XCTAssertEqual(WalletAmountDisplay.fiat(try MASAmount("1"), quote: tiny, currency: "BTC", now: quoteTestNow), "<0.000000000001 BTC")
    }
    func testCryptoUnavailableNeverFallsBackToFiatFXOrFabricatedZero() async {
        for mode: CryptoQuoteTransport.Mode in [.missing,.stale,.mismatchedTime,.zero,.offline] {
            do { _ = try await PublicMassaPriceProvider(transport: CryptoQuoteTransport(mode)).quote(currency: "SOL", now: quoteTestNow); XCTFail("Invalid quote") } catch {}
        }
    }
    func testCurrencySymbolsHaveOneTrailingCodeAndRubleSymbol() throws {
        for (code, expected) in ["USD":"$ 400", "EUR":"€ 400", "RUB":"400 ₽", "AED":"400 AED", "GBP":"£ 400", "JPY":"400 ¥", "CNY":"400 ¥", "INR":"400 ₹"] {
            let quote = FiatQuote(currency: code, perMAS: 4, priceUpdated: quoteTestNow, fxDate: nil)
            XCTAssertEqual(WalletAmountDisplay.fiat(try MASAmount("100"), quote: quote, currency: code, now: quoteTestNow, locale: Locale(identifier: "en_US")), expected)
        }
    }
    @MainActor func testExplicitRefreshBypassesFreshCacheAndFailureRetainsValueHonestly() async {
        let provider = RefreshQuoteMock(), prices = FiatPrices(provider: provider)
        await prices.refresh("USD", now: quoteTestNow)
        let initial = prices.quotes["USD"]
        await prices.refresh("USD", now: quoteTestNow.addingTimeInterval(20), force: true)
        XCTAssertEqual(prices.quotes["USD"]?.perMAS, 2)
        XCTAssertEqual(prices.fetchedAt["USD"], quoteTestNow.addingTimeInterval(20))
        XCTAssertNotEqual(prices.quotes["USD"], initial)
        await prices.refresh("USD", now: quoteTestNow.addingTimeInterval(21), force: true)
        XCTAssertTrue(prices.cooldown.contains("USD"))
        let count = await provider.calls; XCTAssertEqual(count, 2)
        await provider.setFailed()
        await prices.refresh("USD", now: quoteTestNow.addingTimeInterval(40), force: true)
        XCTAssertTrue(prices.errors.contains("USD")); XCTAssertEqual(prices.quotes["USD"]?.perMAS, 2)
        XCTAssertFalse(prices.loading.contains("USD"))
    }
}

extension WalletPresentationTests {
    func testRequestedCurrencyLayoutUsesSymbolsOrOneMutedCodeButNeverBoth() throws {
        let expected = ["USD":"$ 400", "EUR":"€ 400", "GBP":"£ 400", "RUB":"400 ₽", "JPY":"400 ¥", "CNY":"400 ¥", "INR":"400 ₹", "AED":"400 AED", "BTC":"400 BTC", "ETH":"400 ETH", "SOL":"400 SOL"]
        for (code, text) in expected {
            let parts = CurrencyDisplayParts.formatted(number: "400", currency: code)
            XCTAssertEqual(parts.text, text)
            XCTAssertEqual(parts.codeSuffix, ["AED","BTC","ETH","SOL"].contains(code))
        }
        let now = Date(), quote = FiatQuote(currency: "BTC", perMAS: Decimal(string: "0.53")!, priceUpdated: now, fxDate: nil)
        XCTAssertEqual(WalletAmountDisplay.fiat(try MASAmount("1"), quote: quote, currency: "BTC", now: now, locale: Locale(identifier: "en_US")), "0.53 BTC")
        XCTAssertEqual(WalletAmountDisplay.fiat(try MASAmount("1"), quote: quote, currency: "BTC", now: now, locale: Locale(identifier: "de_DE")), "0,53 BTC")
    }
}
