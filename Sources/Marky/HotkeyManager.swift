import AppKit
import KeyboardShortcuts

@MainActor
extension KeyboardShortcuts.Name {
    static let convertToRichText = Self("pasteRichText") // keep existing user-defaults key
    static let restoreOriginal = Self("pasteOriginal")
    static let copyPlainText = Self("copyPlainText")
    static let openHistory = Self("openHistory")
}

/// Registers the global hotkeys and dispatches them to `ClipboardActions`.
/// The clipboard-rewrite hotkeys never paste — the user presses ⌘V.
@MainActor
final class HotkeyManager: ObservableObject {
    private let actions: ClipboardActions

    /// Invoked when the open-history hotkey fires. Set by the app to toggle the
    /// standalone history window. A direct callback is more reliable than observing a
    /// published counter from a SwiftUI scene (scene `.onChange` may not fire when the
    /// menu-bar scene isn't rendering).
    var onOpenHistory: (() -> Void)?

    init(actions: ClipboardActions) {
        self.actions = actions
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
        if KeyboardShortcuts.getShortcut(for: .openHistory) == nil {
            KeyboardShortcuts.setShortcut(.init(.v, modifiers: [.command, .option]), for: .openHistory)
        }
    }

    private func registerHandlers() {
        KeyboardShortcuts.onKeyUp(for: .convertToRichText) { [weak self] in
            self?.actions.convertToRichText()
        }
        KeyboardShortcuts.onKeyUp(for: .restoreOriginal) { [weak self] in
            self?.actions.restoreOriginal()
        }
        KeyboardShortcuts.onKeyUp(for: .copyPlainText) { [weak self] in
            self?.actions.copyPlainText()
        }
        KeyboardShortcuts.onKeyUp(for: .openHistory) { [weak self] in
            self?.onOpenHistory?()
        }
    }
}
