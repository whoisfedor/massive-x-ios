import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en", french = "fr", russian = "ru", spanish = "es", chinese = "zh-Hans", german = "de"
    var id: String { rawValue }
    var name: String {
        switch self { case .english: "English"; case .french: "Français"; case .russian: "Русский"; case .spanish: "Español"; case .chinese: "简体中文"; case .german: "Deutsch" }
    }
    var locale: Locale { Locale(identifier: rawValue) }
}
@MainActor @Observable final class AppLanguageSettings {
    static let shared = AppLanguageSettings()
    private let defaults: UserDefaults
    private(set) var language: AppLanguage
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: "app.language") ?? "en") ?? .english
    }
    func text(_ key: String) -> String { localized(key, language: language) }
    func select(_ language: AppLanguage) {
        // Publish only after runtime catalog lookup can see the new selection.
        defaults.set(language.rawValue, forKey: "app.language"); self.language = language
    }
}
/// For runtime strings/errors; SwiftUI literal keys use the same native localization resources.
/// Read preferences rather than shared mutable state so network errors can localize off the main actor.
func L(_ key: String) -> String {
    let code = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "app.language") ?? "en")?.rawValue ?? "en"
    return localized(key, language: AppLanguage(rawValue: code) ?? .english)
}

func localized(_ key: String, language: AppLanguage) -> String {
    guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
    return bundle.localizedString(forKey: key, value: key, table: nil)
}

func appLocale() -> Locale {
    AppLanguage(rawValue: UserDefaults.standard.string(forKey: "app.language") ?? "en")?.locale ?? Locale(identifier: "en")
}
func localizedDate(_ date: Date) -> String { date.formatted(.dateTime.locale(appLocale())) }
