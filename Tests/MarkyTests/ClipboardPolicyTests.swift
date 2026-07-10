import AppKit
import Foundation
@testable import Marky
import Testing

@MainActor
@Suite struct ClipboardPolicyTests {
    private func makeSettings() -> AppSettings {
        let suiteName = "marky-policy-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(defaults: defaults)
    }

    @Test func excludedAppMatchesFrontmostBundleID() {
        let settings = self.makeSettings()
        settings.excludedApps = ["com.example.secret"]

        let excluded = ClipboardPolicy(settings: settings, frontmostBundleID: { "com.example.secret" })
        #expect(excluded.isFromExcludedApp())

        let other = ClipboardPolicy(settings: settings, frontmostBundleID: { "com.example.other" })
        #expect(!other.isFromExcludedApp())

        let unknown = ClipboardPolicy(settings: settings, frontmostBundleID: { nil })
        #expect(!unknown.isFromExcludedApp())
    }

    @Test func ignorePatternsMatchAndTrackSettingsChanges() {
        let settings = self.makeSettings()
        let policy = ClipboardPolicy(settings: settings, frontmostBundleID: { nil })

        #expect(!policy.matchesIgnorePatterns("ghp_abc123"))

        settings.ignorePatterns = ["^ghp_"]
        #expect(policy.matchesIgnorePatterns("ghp_abc123"))
        #expect(!policy.matchesIgnorePatterns("plain text"))

        // Removing the pattern invalidates the compiled cache.
        settings.ignorePatterns = []
        #expect(!policy.matchesIgnorePatterns("ghp_abc123"))
    }

    @Test func invalidPatternsAreSkipped() {
        let settings = self.makeSettings()
        settings.ignorePatterns = ["([unclosed", "^AKIA"]
        let policy = ClipboardPolicy(settings: settings, frontmostBundleID: { nil })

        #expect(policy.matchesIgnorePatterns("AKIA1234"))
        #expect(!policy.matchesIgnorePatterns("harmless"))
    }

    @Test func sensitiveTypesAreDetected() {
        let settings = self.makeSettings()
        let policy = ClipboardPolicy(settings: settings, frontmostBundleID: { nil })

        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

        #expect(policy.isSensitive(types: [.string, concealed]))
        #expect(policy.isSensitive(types: [transient]))
        #expect(!policy.isSensitive(types: [.string, .rtf]))
        #expect(!policy.isSensitive(types: nil))
    }
}
