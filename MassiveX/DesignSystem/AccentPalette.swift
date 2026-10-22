import Foundation
import Observation

struct PaletteRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    init(_ red: Double, _ green: Double, _ blue: Double) { self.red = red; self.green = green; self.blue = blue }
}

struct PaletteTokens: Equatable, Sendable {
    let background: PaletteRGB
    let surface: PaletteRGB
    let accent: PaletteRGB
}

enum AccentPalette: String, CaseIterable, Identifiable, Sendable {
    case midnightBlue, darkCrimson, orange
    var id: String { rawValue }
    var title: String {
        switch self { case .midnightBlue: "Midnight Blue"; case .darkCrimson: "Dark Crimson"; case .orange: "Orange" }
    }
    func tokens(dark: Bool) -> PaletteTokens {
        switch (self, dark) {
        case (.midnightBlue, true):
            PaletteTokens(background: .init(0.035, 0.039, 0.047), surface: .init(0.075, 0.082, 0.098), accent: .init(0.43, 0.66, 1))
        case (.midnightBlue, false):
            PaletteTokens(background: .init(0.95, 0.96, 0.98), surface: .init(1, 1, 1), accent: .init(0.12, 0.32, 0.80))
        case (.orange, true):
            PaletteTokens(background: .init(0.035, 0.039, 0.047), surface: .init(0.075, 0.082, 0.098), accent: .init(1, 0.64, 0.28))
        case (.orange, false):
            PaletteTokens(background: .init(0.95, 0.96, 0.98), surface: .init(1, 1, 1), accent: .init(0.57, 0.25, 0.02))
        case (.darkCrimson, true):
            PaletteTokens(background: .init(0.055, 0.027, 0.037), surface: .init(0.110, 0.055, 0.075), accent: .init(0.96, 0.47, 0.58))
        case (.darkCrimson, false):
            PaletteTokens(background: .init(0.985, 0.95, 0.96), surface: .init(0.995, 0.98, 0.985), accent: .init(0.65, 0.10, 0.24))
        }
    }
}

@MainActor @Observable final class ThemeSettings {
    static let shared = ThemeSettings()
    private let defaults: UserDefaults
    private(set) var palette: AccentPalette
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        palette = AccentPalette(rawValue: defaults.string(forKey: "accentPalette") ?? "") ?? .midnightBlue
    }
    func select(_ palette: AccentPalette) {
        self.palette = palette
        defaults.set(palette.rawValue, forKey: "accentPalette")
    }
}
