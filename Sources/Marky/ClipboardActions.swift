import Foundation

/// User-triggered clipboard rewrites, shared by the global hotkeys and the UI
/// buttons. These never paste — the user (or the history window's paste flow)
/// does that separately.
@MainActor
final class ClipboardActions: ObservableObject {
    private let monitor: ClipboardMonitor
    private let pasteboard: PasteboardService

    init(monitor: ClipboardMonitor, pasteboard: PasteboardService) {
        self.monitor = monitor
        self.pasteboard = pasteboard
    }

    /// Rewrites the clipboard as rich text (regardless of the auto toggle/detection).
    func convertToRichText() {
        self.monitor.convertClipboardIfNeeded(force: true)
    }

    /// Rewrites the clipboard back to the original markdown as plain text only.
    /// The marker type prevents the monitor from immediately reconverting it.
    func restoreOriginal() {
        let original = self.monitor.lastConversion?.markdown ?? self.pasteboard.readPlainText()
        guard let original else { return }
        self.pasteboard.writePlainText(original)
    }

    /// Strips all rich formatting: rewrites the clipboard as plain text only.
    /// Works on any clipboard content, including rich text copied from other apps.
    func copyPlainText() {
        guard let text = self.pasteboard.extractPlainText() else { return }
        self.pasteboard.writePlainText(text)
    }

    /// Converts arbitrary text to rich text and writes it to the clipboard.
    /// Used by "Copy as Rich Text" and the overlay's pick-to-paste flow.
    @discardableResult
    func convertTextToRichText(_ text: String) -> Bool {
        self.monitor.convertTextToRichText(text)
    }

    /// Restores a history entry through the marked pasteboard write path.
    @discardableResult
    func restore(_ entry: ClipboardEntry, from history: ClipboardHistoryStore) -> Bool {
        switch entry.content {
        case let .text(text):
            self.pasteboard.writePlainText(text)
        case .image:
            guard let pngData = history.pngData(for: entry) else { return false }
            self.pasteboard.writeImagePNG(pngData)
        }
        return true
    }

    /// Copies text and explicitly records it in history.
    /// Marky's marked pasteboard writes are skipped by the monitor, so the
    /// history insertion must happen as part of the same user action.
    func copyAndRecordText(_ text: String, in history: ClipboardHistoryStore) {
        self.pasteboard.writePlainText(text)
        history.recordText(text)
    }
}
