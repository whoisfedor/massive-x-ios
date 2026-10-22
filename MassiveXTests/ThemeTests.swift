import XCTest
@testable import MassiveX

final class ThemeTests: XCTestCase {
    @MainActor func testThemePersistenceDefaultAndAppearanceIndependence() throws {
        let name = "MassiveX.ThemeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("Light", forKey: "appearance")
        let settings = ThemeSettings(defaults: defaults)
        XCTAssertEqual(settings.palette, .midnightBlue)
        settings.select(.darkCrimson)
        XCTAssertEqual(ThemeSettings(defaults: defaults).palette, .darkCrimson)
        XCTAssertEqual(defaults.string(forKey: "appearance"), "Light")
        defaults.set("unsupported", forKey: "accentPalette")
        XCTAssertEqual(ThemeSettings(defaults: defaults).palette, .midnightBlue)
    }
    func testBothAtmospheresChangeBackgroundSurfaceAndAccent() {
        for dark in [false, true] {
            let blue = AccentPalette.midnightBlue.tokens(dark: dark)
            let crimson = AccentPalette.darkCrimson.tokens(dark: dark)
            XCTAssertNotEqual(blue.background, crimson.background)
            XCTAssertNotEqual(blue.surface, crimson.surface)
            XCTAssertNotEqual(blue.accent, crimson.accent)
        }
    }
    func testSemanticContrastForBothAppearances() {
        func luminance(_ rgb: PaletteRGB) -> Double {
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
        }
        func contrast(_ a: PaletteRGB, _ b: PaletteRGB) -> Double {
            let x = luminance(a), y = luminance(b)
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        for palette in AccentPalette.allCases {
            for dark in [false, true] {
                let tokens = palette.tokens(dark: dark)
                for surface in [tokens.background, tokens.surface] {
                    XCTAssertGreaterThanOrEqual(contrast(tokens.accent, surface), 4.5)
                    XCTAssertGreaterThanOrEqual(contrast(dark ? .init(1, 1, 1) : .init(0, 0, 0), surface), 4.5)
                }
                let button = PaletteRGB(tokens.accent.red * 0.12 + tokens.background.red * 0.88,
                                        tokens.accent.green * 0.12 + tokens.background.green * 0.88,
                                        tokens.accent.blue * 0.12 + tokens.background.blue * 0.88)
                XCTAssertGreaterThanOrEqual(contrast(tokens.accent, button), 4.5)
            }
        }
    }
}
