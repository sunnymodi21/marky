import Foundation
import MarkyCore
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let autoConvertEnabled = "autoConvertEnabled"
        static let sensitivity = "sensitivity"
    }

    private let defaults: UserDefaults

    @Published var autoConvertEnabled: Bool {
        didSet { self.defaults.set(self.autoConvertEnabled, forKey: Keys.autoConvertEnabled) }
    }

    @Published var sensitivity: Sensitivity {
        didSet { self.defaults.set(self.sensitivity.rawValue, forKey: Keys.sensitivity) }
    }

    var convertConfig: ConvertConfig {
        ConvertConfig(sensitivity: self.sensitivity)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoConvertEnabled = (defaults.object(forKey: Keys.autoConvertEnabled) as? Bool) ?? true
        self.sensitivity = (defaults.string(forKey: Keys.sensitivity)).flatMap(Sensitivity.init(rawValue:))
            ?? .normal
    }
}
