import AppKit
import Foundation

/// Decides which clipboard content Marky should leave alone: password-manager
/// (concealed/transient) content, writes from user-excluded apps, and text
/// matching user-defined ignore patterns. Pure policy — no pasteboard IO.
@MainActor
final class ClipboardPolicy {
    private static let sensitiveTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    private let settings: AppSettings
    private let frontmostBundleID: () -> String?

    /// Compiled ignore-pattern cache, invalidated when the settings array changes.
    private var cachedPatterns: [String] = []
    private var cachedRegexes: [NSRegularExpression] = []

    init(
        settings: AppSettings,
        frontmostBundleID: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        })
    {
        self.settings = settings
        self.frontmostBundleID = frontmostBundleID
    }

    /// Standard nspasteboard.org types used by password managers and ephemeral copies.
    func isSensitive(types: [NSPasteboard.PasteboardType]?) -> Bool {
        types?.contains(where: Self.sensitiveTypes.contains) == true
    }

    /// True when the frontmost app is in the user's exclusion list.
    func isFromExcludedApp() -> Bool {
        guard let bundleID = self.frontmostBundleID() else { return false }
        return self.settings.excludedApps.contains(bundleID)
    }

    /// True when the clipboard text matches any user-defined ignore regex pattern.
    func matchesIgnorePatterns(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for regex in self.compiledIgnoreRegexes() {
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private func compiledIgnoreRegexes() -> [NSRegularExpression] {
        let patterns = self.settings.ignorePatterns
        if patterns != self.cachedPatterns {
            self.cachedPatterns = patterns
            self.cachedRegexes = patterns.compactMap {
                try? NSRegularExpression(pattern: $0, options: [])
            }
        }
        return self.cachedRegexes
    }
}
