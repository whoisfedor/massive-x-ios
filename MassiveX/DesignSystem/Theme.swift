import SwiftUI
import UIKit

@MainActor enum Theme {
    static let walletSheet = Color(red: 0.025, green: 0.045, blue: 0.09)
    static var background: Color { color(\.background) }
    static var surface: Color { color(\.surface) }
    static var accent: Color { color(\.accent) }
    static let connected = Color(uiColor: .systemGreen)
    static let disconnected = Color(uiColor: .systemRed)
    static let neutralStatus = Color.secondary
    static var warning: Color {
        Color(uiColor: adaptive(dark: PaletteRGB(1, 0.65, 0.25), light: PaletteRGB(0.55, 0.24, 0.02)))
    }
    private static func color(_ key: KeyPath<PaletteTokens, PaletteRGB>) -> Color {
        let selected = ThemeSettings.shared.palette
        return Color(uiColor: adaptive(dark: selected.tokens(dark: true)[keyPath: key], light: selected.tokens(dark: false)[keyPath: key]))
    }
    // UIKit may resolve dynamic colors on a renderer thread. This closure must not
    // inherit MainActor isolation or capture observable settings.
    private nonisolated static func adaptive(dark: PaletteRGB, light: PaletteRGB) -> UIColor {
        UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
    }
}

extension View {
    func surfaceCard() -> some View {
        padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct SectionTitle: View {
    @Environment(AppLanguageSettings.self) private var liveLanguage
    let title: String
    let subtitle: String
    var body: some View {
        let _ = liveLanguage.language
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
            .foregroundStyle(Theme.background).background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}


enum MainnetConnectionPresentation {
    enum State: Equatable { case healthy, offline, checking }
    static func state(lastVerified: Date?, failed: Bool, checking: Bool, now: Date) -> State {
        if checking { return .checking }
        if failed { return .offline }
        guard let lastVerified, (0...60).contains(now.timeIntervalSince(lastVerified)) else { return .checking }
        return .healthy
    }
    static func green(_ state: State, date: Date, reduceMotion: Bool, active: Bool) -> Bool {
        state == .healthy && active && (reduceMotion || date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5) < 0.5)
    }
}
struct MainnetConnectionDot: View {
    let lastVerified: Date?
    let failed: Bool
    let checking: Bool
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppLanguageSettings.self) private var language
    var body: some View {
        if phase == .active {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in dot(at: context.date, active: true) }
        } else { dot(at: Date(), active: false) }
    }
    private func dot(at date: Date, active: Bool) -> some View {
        let status = MainnetConnectionPresentation.state(lastVerified: lastVerified, failed: failed, checking: checking, now: date)
        let green = MainnetConnectionPresentation.green(status, date: date, reduceMotion: reduceMotion, active: active)
        return Circle().fill(status == .offline ? Theme.disconnected : green ? Theme.connected : Theme.neutralStatus)
            .frame(width: 7, height: 7)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: green)
            .accessibilityLabel(language.text(status == .healthy ? "Connected" : status == .offline ? "Offline" : "Checking"))
    }
}


/// The supplied Massa silhouette, separate from the Massive X application icon.
struct MassaCurrencySymbol: View {
    var size: CGFloat = 44
    var body: some View {
        Image("MassaCurrency").renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(Color.white).padding(size * 0.09).frame(width: size, height: size)
            .background(Color(red: 0.91, green: 0.16, blue: 0.22), in: RoundedRectangle(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }
}

/// Native explicit paste interaction; never polls or reads the clipboard on appearance.
struct CompactPasteButton: View {
    let label: String
    let receive: ([String]) -> Void
    var body: some View {
        PasteButton(payloadType: String.self) { values in
            guard UIApplication.shared.applicationState == .active, !UIScreen.main.isCaptured else { return }
            receive(values)
        }.labelStyle(.iconOnly).buttonBorderShape(.roundedRectangle)
            .tint(Theme.accent).frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(label).accessibilityHint(L("Copy text before pasting."))
    }
}

/// Shared amount/unit typography. Accessibility keeps the whole amount as one value.
struct CurrencyAmountText: View {
    let parts: CurrencyDisplayParts
    var unitFont: Font = .caption
    var body: some View {
        (Text(parts.prefix + parts.number) + (parts.codeSuffix
            ? Text(parts.suffix).font(unitFont).foregroundColor(.secondary)
            : Text(parts.suffix)))
            .monospacedDigit().accessibilityLabel(parts.text)
    }
}
