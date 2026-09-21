import AppKit
import Foundation
import MarkyCore

/// All pasteboard reads and writes go through this service. It owns the marker
/// protocol invariant: every write Marky makes carries the `com.sunnymodi.marky`
/// marker type and registers its changeCount, so the monitor never reprocesses
/// (or re-records) Marky's own output.
@MainActor
final class PasteboardService {
    static let markerType = NSPasteboard.PasteboardType("com.sunnymodi.marky")

    let pasteboard: NSPasteboard

    /// changeCounts of Marky's own writes, consumed by the monitor's poll loop.
    private var ignoredChangeCounts: Set<Int> = []

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        self.pasteboard.changeCount
    }

    var types: [NSPasteboard.PasteboardType]? {
        self.pasteboard.types
    }

    var hasMarker: Bool {
        self.pasteboard.types?.contains(Self.markerType) == true
    }

    /// Registers the current pasteboard changeCount as Marky's own write so the
    /// monitor never re-records or re-converts it. Callers that write to the
    /// pasteboard outside this service (e.g. restoring a clip to paste it) call
    /// this immediately after writing.
    func markOwnWrite() {
        self.ignoredChangeCounts.insert(self.pasteboard.changeCount)
    }

    /// True (and consumes the registration) when `count` was one of our own writes.
    func consumeIgnoredChange(_ count: Int) -> Bool {
        let wasIgnored = self.ignoredChangeCounts.remove(count) != nil
        self.ignoredChangeCounts = self.ignoredChangeCounts.filter { $0 > count }
        return wasIgnored
    }

    // MARK: - Reads

    /// Plain text from the pasteboard (the original markdown, even after our own
    /// rich write), with line endings normalized.
    func readPlainText() -> String? {
        guard let text = self.pasteboard.string(forType: .string) else { return nil }
        return Self.normalizeLineEndings(text)
    }

    /// PNG data for an image on the pasteboard (converts TIFF, e.g. screenshots/Preview copies).
    func readImagePNG() -> Data? {
        if let png = self.pasteboard.data(forType: .png) { return png }
        if let tiff = self.pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:])
        {
            return png
        }
        return nil
    }

    /// Best-effort plain text for the current clipboard: prefers the plain-text
    /// representation, falls back to extracting text from RTF or HTML for
    /// clipboards that only carry rich content.
    func extractPlainText() -> String? {
        if let text = self.readPlainText() {
            return text
        }
        if let rtfData = self.pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil)
        {
            return Self.normalizeLineEndings(attributed.string)
        }
        if let htmlData = self.pasteboard.data(forType: .html),
           let attributed = NSAttributedString(
               html: htmlData,
               options: [.documentType: NSAttributedString.DocumentType.html],
               documentAttributes: nil)
        {
            return Self.normalizeLineEndings(attributed.string)
        }
        return nil
    }

    // MARK: - Writes

    /// Writes a single pasteboard item carrying RTF + HTML + original markdown + marker.
    func writeRich(_ result: ConversionResult) {
        let item = NSPasteboardItem()
        item.setData(result.rtf, forType: .rtf)
        item.setString(result.html, forType: .html)
        item.setString(result.markdown, forType: .string)
        item.setData(Data(), forType: Self.markerType)
        self.write(item)
    }

    /// Writes text as the only representation, stripping any rich formatting.
    /// The marker prevents the monitor from re-detecting/converting it.
    func writePlainText(_ text: String) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.markerType)
        self.write(item)
    }

    /// Deep-copies the current pasteboard items so a later `restoreItems`
    /// can put them back. Used by Smart Fill's paste fallback.
    func copyItems() -> [NSPasteboardItem] {
        guard let items = self.pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// Restores a snapshot taken with `copyItems()`, marking the write as ours.
    func restoreItems(_ items: [NSPasteboardItem]) {
        let markerItem = items.first ?? NSPasteboardItem()
        markerItem.setData(Data(), forType: Self.markerType)
        self.pasteboard.clearContents()
        self.pasteboard.writeObjects(items.isEmpty ? [markerItem] : items)
        self.markOwnWrite()
    }

    /// Writes PNG and TIFF image representations with Marky's marker.
    func writeImagePNG(_ pngData: Data) {
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        if let tiff = NSBitmapImageRep(data: pngData)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        item.setData(Data(), forType: Self.markerType)
        self.write(item)
    }

    // MARK: - Helpers

    private func write(_ item: NSPasteboardItem) {
        self.pasteboard.clearContents()
        self.pasteboard.writeObjects([item])
        self.markOwnWrite()
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
