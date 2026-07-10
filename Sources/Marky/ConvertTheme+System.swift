import AppKit
import MarkyCore

extension ConvertTheme {
    /// The theme matching the app's current effective appearance.
    /// Lives in the app target so MarkyCore stays free of appearance lookups.
    @MainActor
    static func system() -> ConvertTheme {
        guard let app = NSApp else { return .light }
        let appearance = app.effectiveAppearance
        let isDark = appearance.bestMatch(
            from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
        return isDark ? .dark : .light
    }
}
