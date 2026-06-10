import AppKit
import KeyboardShortcuts

@MainActor
extension KeyboardShortcuts.Name {
    static let convertToRichText = Self("pasteRichText") // keep existing user-defaults key
    static let restoreOriginal = Self("pasteOriginal")
    static let copyPlainText = Self("copyPlainText")
}

@MainActor
final class HotkeyManager: ObservableObject {
    private let settings: AppSettings
    private let monitor: ClipboardMonitor
    private let permissions: AccessibilityPermissionManager

    init(settings: AppSettings, monitor: ClipboardMonitor, permissions: AccessibilityPermissionManager) {
        self.settings = settings
        self.monitor = monitor
        self.permissions = permissions
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
    /// Pastes only when auto-paste is enabled in Settings; otherwise you paste with ⌘V.
    func convertToRichTextNow() {
        self.monitor.convertClipboardIfNeeded(force: true)
        self.autoPasteIfEnabled()
    }

    /// Rewrites the clipboard back to the original markdown as plain text only.
    /// The marker type prevents the monitor from immediately reconverting it.
    func restoreOriginalNow() {
        let original = self.monitor.lastConversion?.markdown ?? self.monitor.clipboardMarkdown()
        guard let original else { return }
        self.monitor.writePlainMarkdown(original)
        self.autoPasteIfEnabled()
    }

    /// Strips all rich formatting: rewrites the clipboard as plain text only.
    /// Works on any clipboard content, including rich text copied from other apps.
    func copyPlainTextNow() {
        guard let text = self.monitor.plainTextFromClipboard() else { return }
        self.monitor.writePlainText(text, summary: "Stripped formatting to plain text.")
        self.autoPasteIfEnabled()
    }

    private func autoPasteIfEnabled() {
        guard self.settings.autoPasteEnabled else { return }
        self.permissions.refresh()
        guard self.permissions.isTrusted else {
            self.permissions.requestIfNeeded()
            return
        }
        PasteService.sendPasteCommand()
    }
}
