import Foundation

extension Bundle {
    var shortVersion: String {
        (self.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    var buildVersion: String {
        (self.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
}
