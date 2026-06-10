import AppKit
import Foundation
@testable import Marky
import MarkyCore
import Testing

@MainActor
@Suite struct ClipboardMonitorTests {
    private func makeMonitor(autoConvert: Bool = true) -> (ClipboardMonitor, NSPasteboard, AppSettings) {
        let suiteName = "marky-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        settings.autoConvertEnabled = autoConvert

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("marky-tests-\(UUID().uuidString)"))
        let monitor = ClipboardMonitor(settings: settings, pasteboard: pasteboard)
        return (monitor, pasteboard, settings)
    }

    private func setPlainText(_ text: String, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @Test func convertsMarkdownAndPreservesOriginal() {
        let (monitor, pasteboard, _) = self.makeMonitor()
        let markdown = "# Title\n\n**bold** and [link](https://x.com)\n\n- a\n- b"
        self.setPlainText(markdown, on: pasteboard)

        #expect(monitor.convertClipboardIfNeeded(force: false))

        #expect(pasteboard.data(forType: .rtf) != nil)
        #expect(pasteboard.string(forType: .html)?.contains("<h1>") == true)
        #expect(pasteboard.string(forType: .string) == markdown)
        #expect(pasteboard.types?.contains(ClipboardMonitor.markerType) == true)
    }

    @Test func skipsPlainProse() {
        let (monitor, pasteboard, _) = self.makeMonitor()
        self.setPlainText("just a plain sentence without any markup", on: pasteboard)

        #expect(!monitor.convertClipboardIfNeeded(force: false))
        #expect(pasteboard.data(forType: .rtf) == nil)
    }

    @Test func skipsOwnWrites() {
        let (monitor, pasteboard, _) = self.makeMonitor()
        self.setPlainText("# Title\n\n**bold** text\n\n- a\n- b", on: pasteboard)

        #expect(monitor.convertClipboardIfNeeded(force: false))
        // Second pass sees the marker and does nothing.
        #expect(!monitor.convertClipboardIfNeeded(force: false))
    }

    @Test func respectsAutoConvertToggle() {
        let (monitor, pasteboard, _) = self.makeMonitor(autoConvert: false)
        self.setPlainText("# Title\n\n**bold** text", on: pasteboard)

        #expect(!monitor.convertClipboardIfNeeded(force: false))
        // Forcing bypasses the toggle and detection.
        #expect(monitor.convertClipboardIfNeeded(force: true))
        #expect(pasteboard.data(forType: .rtf) != nil)
    }

    @Test func forceConvertsEvenNonMarkdown() {
        let (monitor, pasteboard, _) = self.makeMonitor()
        self.setPlainText("plain text, no markup", on: pasteboard)

        #expect(monitor.convertClipboardIfNeeded(force: true))
        #expect(pasteboard.data(forType: .rtf) != nil)
        #expect(pasteboard.string(forType: .string) == "plain text, no markup")
    }

    @Test func plainMarkdownWriteCarriesMarker() {
        let (monitor, pasteboard, _) = self.makeMonitor()
        monitor.writePlainMarkdown("# restored")

        #expect(pasteboard.string(forType: .string) == "# restored")
        #expect(pasteboard.data(forType: .rtf) == nil)
        #expect(pasteboard.types?.contains(ClipboardMonitor.markerType) == true)
        #expect(!monitor.convertClipboardIfNeeded(force: false))
    }

    @Test func plainTextPrefersStringRepresentation() {
        let (monitor, pasteboard, _) = self.makeMonitor()
        self.setPlainText("# Title\n\n**bold**", on: pasteboard)
        #expect(monitor.convertClipboardIfNeeded(force: false))

        // After conversion the clipboard is rich, but plain text is the original markdown.
        #expect(monitor.plainTextFromClipboard() == "# Title\n\n**bold**")
    }

    @Test func plainTextFallsBackToRTFExtraction() {
        let (monitor, pasteboard, _) = self.makeMonitor()

        let attributed = NSAttributedString(string: "rich only content")
        let rtf = attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])!
        pasteboard.clearContents()
        pasteboard.setData(rtf, forType: .rtf)

        #expect(monitor.plainTextFromClipboard() == "rich only content")
    }

    @Test func copyAsPlainTextStripsRichRepresentations() {
        let (monitor, pasteboard, _) = self.makeMonitor()
        self.setPlainText("# Title\n\n**bold** text\n\n- a\n- b", on: pasteboard)
        #expect(monitor.convertClipboardIfNeeded(force: false))
        #expect(pasteboard.data(forType: .rtf) != nil)

        let plain = monitor.plainTextFromClipboard()!
        monitor.writePlainText(plain, summary: "Stripped formatting to plain text.")

        #expect(pasteboard.data(forType: .rtf) == nil)
        #expect(pasteboard.string(forType: .html) == nil)
        #expect(pasteboard.string(forType: .string) == plain)
        #expect(pasteboard.types?.contains(ClipboardMonitor.markerType) == true)
        // Marker prevents the monitor from reconverting the markdown-shaped text.
        #expect(!monitor.convertClipboardIfNeeded(force: false))
    }

    @Test func ellipsizeKeepsHeadAndTail() {
        let text = String(repeating: "a", count: 60) + String(repeating: "b", count: 60)
        let result = ClipboardMonitor.ellipsize(text, limit: 41)
        #expect(result.count == 41)
        #expect(result.contains("…"))
        #expect(result.hasPrefix("aaaa"))
        #expect(result.hasSuffix("bbbb"))
    }
}
