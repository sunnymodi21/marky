import AppKit
import ApplicationServices

/// Synthetic paste (CGEvent ⌘V) requires the Accessibility permission.
/// Clipboard watching does not.
@MainActor
final class AccessibilityPermissionManager: ObservableObject {
    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    func refresh() {
        self.isTrusted = AXIsProcessTrusted()
    }

    /// Prompts the user with the system Accessibility dialog if not yet trusted.
    func requestIfNeeded() {
        // String literal avoids touching the non-Sendable kAXTrustedCheckOptionPrompt global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        self.isTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
