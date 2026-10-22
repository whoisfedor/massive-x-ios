import Foundation
import Observation

struct FiatCurrency: Identifiable, Equatable, Sendable {
    let id: String
    var name: String { ["BTC": "Bitcoin", "ETH": "Ethereum", "SOL": "Solana"][id] ?? appLocale().localizedString(forCurrencyCode: id) ?? id }
    static let cryptoIDs = ["BTC": "bitcoin", "ETH": "ethereum", "SOL": "solana"]
    var symbol: String {
        if Self.cryptoIDs[id] != nil { return id }
        let format = NumberFormatter(); format.numberStyle = .currency; format.locale = appLocale(); format.currencyCode = id
        return format.currencySymbol ?? id
    }
    static let preferred = ["USD", "EUR", "RUB", "BTC", "ETH", "SOL", "JPY", "AED", "KZT", "UAH", "GBP", "CHF", "CNY", "KRW", "IDR", "INR"]
    static let all: [FiatCurrency] = {
        let existing = Array(Set(Locale.commonISOCurrencyCodes + Array(cryptoIDs.keys))).sorted()
        return (preferred.filter { existing.contains($0) } + existing.filter { !preferred.contains($0) }).map { FiatCurrency(id: $0) }
    }()
    static func recognized(_ code: String) -> Bool { all.contains { $0.id == code } }
    static func matching(_ search: String) -> [FiatCurrency] {
        guard !search.isEmpty else { return all }
        return all.filter { ($0.id + " " + $0.name + " " + $0.symbol).localizedCaseInsensitiveContains(search) }
    }
}

@MainActor @Observable final class FiatSettings {
    private let defaults: UserDefaults
    private(set) var currency: String
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: "fiatCurrency") ?? "USD"
        currency = FiatCurrency.recognized(saved) ? saved : "USD"
    }
    func select(_ code: String) {
        guard FiatCurrency.recognized(code) else { return }
        currency = code; defaults.set(code, forKey: "fiatCurrency")
    }
}

struct FiatQuote: Equatable, Sendable {
    let currency: String
    let perMAS: Decimal
    let priceUpdated: Date
    let fxDate: Date?
    var source: String { fxDate == nil ? "CoinGecko" : "CoinGecko + Frankfurter" }
    func usable(at now: Date) -> Bool {
        perMAS > 0 && !perMAS.isNaN && priceUpdated <= now.addingTimeInterval(60)
            && now.timeIntervalSince(priceUpdated) <= 900
            && (fxDate.map { $0 <= now.addingTimeInterval(86_400) && now.timeIntervalSince($0) <= 7 * 86_400 } ?? true)
    }
}
protocol MassaPriceProviding: Sendable {
    func quote(currency: String, now: Date) async throws -> FiatQuote
}
enum FiatPriceError: Error { case unavailable, invalidResponse, stale, unsupported }

/// Public market data only. Requests never contain a wallet address, identifier or key.
actor PublicMassaPriceProvider: MassaPriceProviding {
    private let transport: any RPCTransport
    private var supported: Set<String> = []
    private var supportedAt: Date?
    init(transport: any RPCTransport = MainnetURLSessionTransport()) { self.transport = transport }
    private func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        guard let host = url.host, url.scheme == "https", ["api.coingecko.com", "api.frankfurter.dev"].contains(host) else { throw FiatPriceError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.send(request)
        guard response.statusCode == 200, response.data.count <= 1_048_576 else { throw FiatPriceError.unavailable }
        guard let value = try? JSONDecoder().decode(T.self, from: response.data) else { throw FiatPriceError.invalidResponse }
        return value
    }
    func quote(currency: String, now: Date) async throws -> FiatQuote {
        guard currency.utf8.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }) else { throw FiatPriceError.unsupported }
        if let assetID = FiatCurrency.cryptoIDs[currency] {
            var components = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
            components.queryItems = [URLQueryItem(name: "ids", value: "massa," + assetID),
                                     URLQueryItem(name: "vs_currencies", value: "usd"),
                                     URLQueryItem(name: "include_last_updated_at", value: "true"),
                                     URLQueryItem(name: "precision", value: "full")]
            let values = try await get(components.url!, as: [String: [String: Decimal]].self)
            guard let mas = values["massa"], let coin = values[assetID],
                  let usd = mas["usd"], let denominator = coin["usd"], usd > 0, denominator > 0,
                  let masTime = mas["last_updated_at"], let coinTime = coin["last_updated_at"] else { throw FiatPriceError.invalidResponse }
            let dates = [masTime, coinTime].map { Date(timeIntervalSince1970: NSDecimalNumber(decimal: $0).doubleValue) }
            guard dates.allSatisfy({ $0 <= now.addingTimeInterval(60) && now.timeIntervalSince($0) <= 900 }),
                  abs(dates[0].timeIntervalSince(dates[1])) <= 300 else { throw FiatPriceError.stale }
            let result = FiatQuote(currency: currency, perMAS: usd / denominator, priceUpdated: min(dates[0], dates[1]), fxDate: nil)
            guard result.usable(at: now) else { throw FiatPriceError.invalidResponse }
            return result
        }
        if supportedAt == nil || now.timeIntervalSince(supportedAt!) > 6 * 3600 {
            let list = try await get(URL(string: "https://api.coingecko.com/api/v3/simple/supported_vs_currencies")!, as: [String].self)
            guard list.contains("usd") else { throw FiatPriceError.invalidResponse }
            supported = Set(list); supportedAt = now
        }
        let direct = supported.contains(currency.lowercased())
        let quoteCode = direct ? currency.lowercased() : "usd"
        var components = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        components.queryItems = [URLQueryItem(name: "ids", value: "massa"), URLQueryItem(name: "vs_currencies", value: quoteCode),
                                 URLQueryItem(name: "include_last_updated_at", value: "true")]
        let prices = try await get(components.url!, as: [String: [String: Decimal]].self)
        guard let asset = prices["massa"], let rate = asset[quoteCode], rate > 0,
              let timestamp = asset["last_updated_at"] else { throw FiatPriceError.invalidResponse }
        let updated = Date(timeIntervalSince1970: NSDecimalNumber(decimal: timestamp).doubleValue)
        let usdOrDirect = FiatQuote(currency: currency, perMAS: rate, priceUpdated: updated, fxDate: nil)
        guard usdOrDirect.usable(at: now) else { throw FiatPriceError.stale }
        if direct { return usdOrDirect }
        struct FX: Decodable { let date: String; let base: String; let quote: String; let rate: Decimal }
        let fx = try await get(URL(string: "https://api.frankfurter.dev/v2/rate/USD/\(currency)")!, as: FX.self)
        let dateFormat = DateFormatter(); dateFormat.locale = Locale(identifier: "en_US_POSIX")
        dateFormat.timeZone = TimeZone(secondsFromGMT: 0); dateFormat.dateFormat = "yyyy-MM-dd"; dateFormat.isLenient = false
        guard fx.base.uppercased() == "USD", fx.quote.uppercased() == currency, fx.rate > 0,
              let date = dateFormat.date(from: fx.date), dateFormat.string(from: date) == fx.date else { throw FiatPriceError.invalidResponse }
        let result = FiatQuote(currency: currency, perMAS: rate * fx.rate, priceUpdated: updated, fxDate: date)
        guard result.usable(at: now) else { throw FiatPriceError.stale }
        return result
    }
}

@MainActor @Observable final class FiatPrices {
    private(set) var quotes: [String: FiatQuote] = [:]
    private(set) var errors: Set<String> = []
    private(set) var loading: Set<String> = []
    private(set) var fetchedAt: [String: Date] = [:]
    private(set) var cooldown: Set<String> = []
    private var attempted: [String: Date] = [:]
    @ObservationIgnored private var expirations: [String: Task<Void, Never>] = [:]
    private let provider: any MassaPriceProviding
    init(provider: any MassaPriceProviding = PublicMassaPriceProvider()) { self.provider = provider }
    func quote(_ currency: String, now: Date = Date()) -> FiatQuote? {
        guard let value = quotes[currency], value.usable(at: now) else { return nil }
        return value
    }
    func refresh(_ currency: String, now: Date = Date(), force: Bool = false) async {
        guard !loading.contains(currency) else { return }
        if let previous = attempted[currency], now.timeIntervalSince(previous) < (force ? 15 : 60) {
            if force { cooldown.insert(currency) }; return
        }
        if !force, let previous = quote(currency, now: now), now.timeIntervalSince(previous.priceUpdated) < 300 { return }
        cooldown.remove(currency)
        attempted[currency] = now; loading.insert(currency)
        defer { loading.remove(currency) }
        do {
            let result = try await provider.quote(currency: currency, now: now)
            guard result.currency == currency, result.usable(at: now) else { throw FiatPriceError.invalidResponse }
            quotes[currency] = result; fetchedAt[currency] = now; errors.remove(currency)
            expirations[currency]?.cancel()
            let priceLife = max(0, min(900, 900 - now.timeIntervalSince(result.priceUpdated)))
            let fxLife = result.fxDate.map { max(0, 7 * 86_400 - now.timeIntervalSince($0)) } ?? priceLife
            expirations[currency] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(min(priceLife, fxLife))) } catch { return }
                if self?.quotes[currency] == result { self?.errors.insert(currency) }
            }
        } catch {
            if !Task.isCancelled { errors.insert(currency) }
        }
    }
}

enum WalletAmountDisplay {
    static func summary(_ amount: MASAmount?, showFiat: Bool, hidden: Bool, quote: FiatQuote?, currency: String,
                        now: Date = Date(), locale: Locale = appLocale()) -> String {
        if hidden { return "••••••" }
        if showFiat { return fiat(amount, quote: quote, currency: currency, now: now, locale: locale) }
        return amount.map { mas($0, locale: locale) } ?? L("Unavailable")
    }
    static func decimal(_ amount: MASAmount) -> Decimal { Decimal(string: String(amount.nano))! / Decimal(1_000_000_000) }
    static func mas(_ amount: MASAmount, locale: Locale = appLocale()) -> String {
        let format = NumberFormatter(); format.locale = locale; format.numberStyle = .decimal
        format.minimumFractionDigits = 2; format.maximumFractionDigits = 2; format.roundingMode = .halfEven
        return format.string(from: NSDecimalNumber(decimal: decimal(amount))) ?? L("Unavailable")
    }
    static func fiat(_ amount: MASAmount?, quote: FiatQuote?, currency: String, now: Date = Date(), locale: Locale = appLocale()) -> String {
        fiatParts(amount, quote: quote, currency: currency, now: now, locale: locale).text
    }
    static func fiatParts(_ amount: MASAmount?, quote: FiatQuote?, currency: String, now: Date = Date(), locale: Locale = appLocale()) -> CurrencyDisplayParts {
        let unavailable = CurrencyDisplayParts(number: L("Fiat value unavailable"))
        guard let amount, let quote, quote.currency == currency, quote.usable(at: now) else { return unavailable }
        let value = decimal(amount) * quote.perMAS
        guard !value.isNaN else { return unavailable }
        let crypto = FiatCurrency.cryptoIDs[currency] != nil
        let format = NumberFormatter(); format.locale = locale; format.numberStyle = .decimal
        format.minimumFractionDigits = 0; format.maximumFractionDigits = crypto ? 12 : 2
        format.roundingMode = .halfEven
        guard let number = format.string(from: NSDecimalNumber(decimal: value)) else { return unavailable }
        if crypto, value > 0, value < Decimal(string: "0.000000000001")! {
            return CurrencyDisplayParts.formatted(number: "<0.000000000001", currency: currency)
        }
        return CurrencyDisplayParts.formatted(number: number, currency: currency)
    }
}

struct CurrencyDisplayParts: Equatable {
    var prefix = ""
    let number: String
    var suffix = ""
    var codeSuffix = false
    var text: String { prefix + number + suffix }
    static func formatted(number: String, currency: String) -> Self {
        if let symbol = ["USD": "$", "EUR": "€", "GBP": "£"][currency] {
            return Self(prefix: symbol + " ", number: number)
        }
        if let symbol = ["RUB": "₽", "JPY": "¥", "CNY": "¥", "INR": "₹"][currency] {
            return Self(number: number, suffix: " " + symbol)
        }
        return Self(number: number, suffix: " " + currency, codeSuffix: true)
    }
}
