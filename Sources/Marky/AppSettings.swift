import Foundation
import MarkyCore
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let autoConvertEnabled = "autoConvertEnabled"
        static let historyEnabled = "historyEnabled"
        static let historyRememberLimit = "historyRememberLimit"
        static let historyDisplayLimit = "historyDisplayLimit"
        static let excludedApps = "excludedApps"
        static let ignorePatterns = "ignorePatterns"
        static let outputFontSize = "outputFontSize"
        static let autoPasteEnabled = "autoPasteEnabled"
    }

    private let defaults: UserDefaults

    @Published var autoConvertEnabled: Bool {
        didSet { self.defaults.set(self.autoConvertEnabled, forKey: Keys.autoConvertEnabled) }
    }

    @Published var historyEnabled: Bool {
        didSet { self.defaults.set(self.historyEnabled, forKey: Keys.historyEnabled) }
    }

    /// How many clippings to keep (CopyClip's "remember" preference).
    @Published var historyRememberLimit: Int {
        didSet { self.defaults.set(self.historyRememberLimit, forKey: Keys.historyRememberLimit) }
    }

    /// How many clippings to show in the menu (CopyClip's "display" preference).
    @Published var historyDisplayLimit: Int {
        didSet { self.defaults.set(self.historyDisplayLimit, forKey: Keys.historyDisplayLimit) }
    }

    /// Bundle IDs of apps whose clipboard writes should be skipped (no history, no auto-convert).
    @Published var excludedApps: [String] {
        didSet { self.defaults.set(self.excludedApps, forKey: Keys.excludedApps) }
    }

    /// User-defined regex patterns. Clipboard text matching any pattern is skipped.
    @Published var ignorePatterns: [String] {
        didSet { self.defaults.set(self.ignorePatterns, forKey: Keys.ignorePatterns) }
    }

    /// Base font size (px) for the rich-text output.
    @Published var outputFontSize: Int {
        didSet { self.defaults.set(self.outputFontSize, forKey: Keys.outputFontSize) }
    }

    /// When enabled, clicking a clip in the standalone history window pastes it
    /// into the previously focused app. Direct-download builds use Accessibility
    /// (CGEvent); the App Store build uses System Events. Falls back to copy-only
    /// if the user declines.
    @Published var autoPasteEnabled: Bool {
        didSet { self.defaults.set(self.autoPasteEnabled, forKey: Keys.autoPasteEnabled) }
    }

    var convertConfig: ConvertConfig {
        ConvertConfig()
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoConvertEnabled = (defaults.object(forKey: Keys.autoConvertEnabled) as? Bool) ?? true
        self.historyEnabled = (defaults.object(forKey: Keys.historyEnabled) as? Bool) ?? true
        self.historyRememberLimit = (defaults.object(forKey: Keys.historyRememberLimit) as? Int) ?? 50
        self.historyDisplayLimit = (defaults.object(forKey: Keys.historyDisplayLimit) as? Int) ?? 15
        self.excludedApps = (defaults.array(forKey: Keys.excludedApps) as? [String]) ?? []
        self.ignorePatterns = (defaults.array(forKey: Keys.ignorePatterns) as? [String]) ?? []
        self.outputFontSize = (defaults.object(forKey: Keys.outputFontSize) as? Int) ?? 13
        self.autoPasteEnabled = (defaults.object(forKey: Keys.autoPasteEnabled) as? Bool) ?? true
    }
}
