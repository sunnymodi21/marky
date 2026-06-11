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

    var convertConfig: ConvertConfig {
        ConvertConfig()
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoConvertEnabled = (defaults.object(forKey: Keys.autoConvertEnabled) as? Bool) ?? true
        self.historyEnabled = (defaults.object(forKey: Keys.historyEnabled) as? Bool) ?? true
        self.historyRememberLimit = (defaults.object(forKey: Keys.historyRememberLimit) as? Int) ?? 50
        self.historyDisplayLimit = (defaults.object(forKey: Keys.historyDisplayLimit) as? Int) ?? 15
    }
}
