import AppKit
import KeyboardShortcuts

@MainActor
extension KeyboardShortcuts.Name {
    static let convertToRichText = Self("pasteRichText") // keep existing user-defaults key
    static let restoreOriginal = Self("pasteOriginal")
    static let copyPlainText = Self("copyPlainText")
}

/// Global hotkeys that rewrite the clipboard; paste manually with ⌘V.
/// No Accessibility permission needed — Marky never synthesizes keystrokes.
@MainActor
final class HotkeyManager: ObservableObject {
    private let monitor: ClipboardMonitor

    init(monitor: ClipboardMonitor) {
        self.monitor = monitor
        self.ensureDefaultShortcuts()
        self.registerHandlers()
    }

    private func ensureDefaultShortcuts() {
        if KeyboardShortcuts.getShortcut(for: .convertToRichText) == nil {
            KeyboardShortcuts.setShortcut(.init(.m, modifiers: [.command, .option]), for: .convertToRichText)
        }
        if KeyboardShortcuts.getShortcut(for: .restoreOriginal) == nil {
            KeyboardShortcuts.setShortcut(
                .init(.m, modifiers: [.command, .option, .shift]),
                for: .restoreOriginal)
        }
        if KeyboardShortcuts.getShortcut(for: .copyPlainText) == nil {
            KeyboardShortcuts.setShortcut(.init(.p, modifiers: [.command, .option]), for: .copyPlainText)
        }
    }

    private func registerHandlers() {
        KeyboardShortcuts.onKeyUp(for: .convertToRichText) { [weak self] in
            self?.convertToRichTextNow()
        }
        KeyboardShortcuts.onKeyUp(for: .restoreOriginal) { [weak self] in
            self?.restoreOriginalNow()
        }
        KeyboardShortcuts.onKeyUp(for: .copyPlainText) { [weak self] in
            self?.copyPlainTextNow()
        }
    }

    /// Rewrites the clipboard as rich text (regardless of the auto toggle/detection).
    func convertToRichTextNow() {
        self.monitor.convertClipboardIfNeeded(force: true)
    }

    /// Rewrites the clipboard back to the original markdown as plain text only.
    /// The marker type prevents the monitor from immediately reconverting it.
    func restoreOriginalNow() {
        let original = self.monitor.lastConversion?.markdown ?? self.monitor.clipboardMarkdown()
        guard let original else { return }
        self.monitor.writePlainMarkdown(original)
    }

    /// Strips all rich formatting: rewrites the clipboard as plain text only.
    /// Works on any clipboard content, including rich text copied from other apps.
    func copyPlainTextNow() {
        guard let text = self.monitor.plainTextFromClipboard() else { return }
        self.monitor.writePlainText(text, summary: "Stripped formatting to plain text.")
    }
}
