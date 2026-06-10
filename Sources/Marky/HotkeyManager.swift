import AppKit
import KeyboardShortcuts

@MainActor
extension KeyboardShortcuts.Name {
    static let pasteRichText = Self("pasteRichText")
    static let pasteOriginal = Self("pasteOriginal")
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
        if KeyboardShortcuts.getShortcut(for: .pasteRichText) == nil {
            KeyboardShortcuts.setShortcut(.init(.m, modifiers: [.command, .option]), for: .pasteRichText)
        }
        if KeyboardShortcuts.getShortcut(for: .pasteOriginal) == nil {
            KeyboardShortcuts.setShortcut(.init(.m, modifiers: [.command, .option, .shift]), for: .pasteOriginal)
        }
    }

    private func registerHandlers() {
        KeyboardShortcuts.onKeyUp(for: .pasteRichText) { [weak self] in
            self?.pasteRichTextNow()
        }
        KeyboardShortcuts.onKeyUp(for: .pasteOriginal) { [weak self] in
            self?.pasteOriginalNow()
        }
    }

    /// Force-converts the clipboard (regardless of auto toggle/detection) and pastes.
    func pasteRichTextNow() {
        guard self.checkAccessibility() else { return }
        self.monitor.convertClipboardIfNeeded(force: true)
        PasteService.sendPasteCommand()
    }

    /// Temporarily restores the original markdown as plain text, pastes,
    /// then restores the rich version.
    func pasteOriginalNow() {
        guard self.checkAccessibility() else { return }

        let original = self.monitor.lastConversion?.markdown ?? self.monitor.clipboardMarkdown()
        guard let original else { return }

        let richToRestore = self.monitor.hasMarker ? self.monitor.lastConversion : nil
        self.monitor.writePlainMarkdown(original)
        PasteService.sendPasteCommand()

        if let richToRestore {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                self?.monitor.writeRich(richToRestore)
            }
        }
    }

    private func checkAccessibility() -> Bool {
        self.permissions.refresh()
        guard self.permissions.isTrusted else {
            self.permissions.requestIfNeeded()
            return false
        }
        return true
    }
}
