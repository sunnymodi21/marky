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

    /// Writes plain text (marked as our own) — e.g. OCR results from image clippings.
    func writePlainText(_ text: String) {
        self.pasteboard.writePlainText(text)
    }

    /// Copies a non-destructively edited clipping and explicitly records it.
    /// Marky's marked pasteboard writes are skipped by the monitor, so the
    /// history insertion must happen as part of the same user action.
    func copyEditedText(_ text: String, recordingIn history: ClipboardHistoryStore) {
        self.pasteboard.writePlainText(text)
        history.recordText(text)
    }
}
