import AppKit
import Foundation
@testable import Marky
import Testing

@MainActor
@Suite struct HistoryCaptureTests {
    private func makeStack() -> (ClipboardMonitor, ClipboardHistoryStore, NSPasteboard, AppSettings) {
        let suiteName = "marky-capture-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("marky-tests-\(UUID().uuidString)"))
        let service = PasteboardService(pasteboard: pasteboard)
        let policy = ClipboardPolicy(settings: settings, frontmostBundleID: { nil })
        let history = ClipboardHistoryStore(settings: settings, storageURL: nil)
        let monitor = ClipboardMonitor(
            settings: settings, pasteboardService: service, policy: policy, history: history)
        return (monitor, history, pasteboard, settings)
    }

    @Test func capturesCopiedText() {
        let (monitor, history, pasteboard, _) = self.makeStack()
        pasteboard.clearContents()
        pasteboard.setString("copied text", forType: .string)

        monitor.captureClipboardForHistory()
        #expect(history.entries.first?.content == .text("copied text"))
    }

    @Test func capturesCopiedImage() {
        let (monitor, history, pasteboard, _) = self.makeStack()
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!

        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)

        monitor.captureClipboardForHistory()
        #expect(history.entries.count == 1)
        if case .image = history.entries[0].content {} else {
            Issue.record("expected an image entry")
        }
    }

    @Test func convertsTIFFOnlyImagesToPNG() {
        let (monitor, history, pasteboard, _) = self.makeStack()
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

        pasteboard.clearContents()
        pasteboard.setData(rep.tiffRepresentation!, forType: .tiff)

        monitor.captureClipboardForHistory()
        #expect(history.entries.count == 1)
        if case .image = history.entries[0].content {} else {
            Issue.record("expected an image entry converted from TIFF")
        }
    }

    @Test func skipsConcealedContent() {
        let (monitor, history, pasteboard, _) = self.makeStack()
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))

        monitor.captureClipboardForHistory()
        #expect(history.entries.isEmpty)
        // Conversion also skips concealed content.
        #expect(!monitor.convertClipboardIfNeeded(force: false))
    }

    @Test func skipsOwnRichWrites() {
        let (monitor, history, pasteboard, _) = self.makeStack()
        pasteboard.clearContents()
        pasteboard.setString("# Title\n\n**bold** text\n\n- a\n- b", forType: .string)
        monitor.captureClipboardForHistory()
        #expect(monitor.convertClipboardIfNeeded(force: false))
        #expect(history.entries.count == 1)

        // The rich rewrite carries the marker; capturing again must not duplicate.
        monitor.captureClipboardForHistory()
        #expect(history.entries.count == 1)
    }

    @Test func respectsHistoryToggle() {
        let (monitor, history, pasteboard, settings) = self.makeStack()
        settings.historyEnabled = false
        pasteboard.clearContents()
        pasteboard.setString("not recorded", forType: .string)

        monitor.captureClipboardForHistory()
        #expect(history.entries.isEmpty)
    }
}
