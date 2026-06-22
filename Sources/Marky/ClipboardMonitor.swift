import AppKit
import Foundation
import MarkyCore

/// Watches the system pasteboard and rewrites Markdown as rich text.
///
/// macOS has no clipboard-change
/// notification API, so we poll `changeCount` every ~150ms, wait a short grace
/// delay for promised pasteboard data, then detect + convert. Our own writes carry
/// a marker pasteboard type so we never reprocess them.
@MainActor
final class ClipboardMonitor: ObservableObject {
    static let markerType = NSPasteboard.PasteboardType("com.sunnymodi.marky")

    private let settings: AppSettings
    private let pasteboard: NSPasteboard
    private let history: ClipboardHistoryStore?
    private let converter = MarkdownConverter()
    private let detector = MarkdownDetector()

    private var timer: DispatchSourceTimer?
    private var lastSeenChangeCount: Int
    private var ignoredChangeCounts: Set<Int> = []
    private var pendingGrace: DispatchWorkItem?

    private let pollInterval: DispatchTimeInterval = .milliseconds(150)
    private let pollLeeway: DispatchTimeInterval = .milliseconds(50)
    private let graceDelay: DispatchTimeInterval = .milliseconds(80)

    @Published private(set) var convertPulseID: Int = 0
    @Published private(set) var conversionCount: Int = 0
    private(set) var lastConversion: ConversionResult?

    init(settings: AppSettings, pasteboard: NSPasteboard = .general, history: ClipboardHistoryStore? = nil) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.history = history
        self.lastSeenChangeCount = pasteboard.changeCount
    }

    // MARK: - Polling

    func start() {
        self.stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: self.pollInterval, leeway: self.pollLeeway)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        self.timer?.cancel()
        self.timer = nil
    }

    private func tick() {
        let current = self.pasteboard.changeCount
        guard current != self.lastSeenChangeCount else { return }

        if self.ignoredChangeCounts.remove(current) != nil {
            self.lastSeenChangeCount = current
            return
        }

        // Update immediately so subsequent ticks for the same or intermediate
        // changes don't schedule redundant grace delays.
        self.lastSeenChangeCount = current

        // Cancel any in-flight grace delay from a previous change; only the
        // latest clipboard state matters after the delay settles.
        self.pendingGrace?.cancel()

        let observed = current
        // Grace delay lets promised pasteboard data settle before we read/transform.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only process if no further change arrived after we scheduled.
            guard observed == self.pasteboard.changeCount else { return }
            self.captureClipboardForHistory()
            self.convertClipboardIfNeeded(force: false)
        }
        self.pendingGrace = work
        DispatchQueue.main.asyncAfter(deadline: .now() + self.graceDelay, execute: work)
    }

    // MARK: - Conversion

    /// Reads the clipboard and, if it looks like Markdown (or `force` is set),
    /// rewrites it with rich representations. Returns true when a conversion happened.
    @discardableResult
    func convertClipboardIfNeeded(force: Bool = false) -> Bool {
        self.lastSeenChangeCount = self.pasteboard.changeCount

        guard self.settings.autoConvertEnabled || force else { return false }

        let alreadyConverted = self.hasMarker
        if alreadyConverted, !force { return false }
        if self.isSensitiveContent, !force { return false }
        if !force, self.isFromExcludedApp { return false }

        guard let markdown = self.clipboardMarkdown(),
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        if !force, self.matchesIgnorePatterns(markdown) { return false }

        if !force {
            guard self.detector.isMarkdown(markdown, config: self.settings.convertConfig) else { return false }
        }

        guard let result = self.converter.convert(markdown, fontSize: self.settings.outputFontSize) else {
            return false
        }

        self.writeRich(result)
        self.lastConversion = result
        self.convertPulseID &+= 1
        self.conversionCount &+= 1
        return true
    }

    // MARK: - History capture

    /// Records the current clipboard (text or image) into the history.
    /// Skips our own writes, concealed/transient content (password managers),
    /// and clipboard writes from excluded apps.
    func captureClipboardForHistory() {
        guard let history = self.history, self.settings.historyEnabled else { return }
        guard !self.hasMarker, !self.isSensitiveContent, !self.isFromExcludedApp else { return }

        if let text = self.clipboardMarkdown() {
            guard !self.matchesIgnorePatterns(text) else { return }
            history.recordText(text)
        } else if let pngData = self.readImagePNG() {
            history.recordImage(pngData: pngData)
        }
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

    // MARK: - Pasteboard IO

    var hasMarker: Bool {
        self.pasteboard.types?.contains(Self.markerType) == true
    }

    /// Standard nspasteboard.org types used by password managers and ephemeral copies.
    var isSensitiveContent: Bool {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let types = self.pasteboard.types ?? []
        return types.contains(concealed) || types.contains(transient)
    }

    /// True when the frontmost app is in the user's exclusion list.
    var isFromExcludedApp: Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return self.settings.excludedApps.contains(bundleID)
    }

    /// True when the clipboard text matches any user-defined ignore regex pattern.
    func matchesIgnorePatterns(_ text: String) -> Bool {
        for pattern in self.settings.ignorePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    /// Plain text from the pasteboard (the original markdown, even after our own write).
    func clipboardMarkdown() -> String? {
        guard let text = self.pasteboard.string(forType: .string) else { return nil }
        return self.normalizeLineEndings(text)
    }

    /// Writes a single pasteboard item carrying RTF + HTML + original markdown + marker.
    func writeRich(_ result: ConversionResult) {
        let item = NSPasteboardItem()
        item.setData(result.rtf, forType: .rtf)
        item.setString(result.html, forType: .html)
        item.setString(result.markdown, forType: .string)
        item.setData(Data(), forType: Self.markerType)

        self.pasteboard.clearContents()
        self.pasteboard.writeObjects([item])
        self.markOwnWrite()
    }

    /// Writes markdown as plain text only (still marked so we don't reconvert it).
    func writePlainMarkdown(_ markdown: String) {
        self.writePlainText(markdown)
    }

    /// Writes text as the only representation, stripping any rich formatting.
    /// The marker prevents the monitor from re-detecting/converting it.
    func writePlainText(_ text: String) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.markerType)

        self.pasteboard.clearContents()
        self.pasteboard.writeObjects([item])
        self.markOwnWrite()
    }

    /// Converts arbitrary text to rich text and writes it to the clipboard.
    /// Used by "Copy as Rich Text" from history entries. Always forces conversion.
    @discardableResult
    func convertTextToRichText(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let result = self.converter.convert(text, fontSize: self.settings.outputFontSize) else {
            return false
        }
        self.writeRich(result)
        self.lastConversion = result
        self.convertPulseID &+= 1
        self.conversionCount &+= 1
        return true
    }

    /// Best-effort plain text for the current clipboard: prefers the plain-text
    /// representation, falls back to extracting text from RTF or HTML for
    /// clipboards that only carry rich content.
    func plainTextFromClipboard() -> String? {
        if let text = self.pasteboard.string(forType: .string) {
            return self.normalizeLineEndings(text)
        }
        if let rtfData = self.pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil)
        {
            return self.normalizeLineEndings(attributed.string)
        }
        if let htmlData = self.pasteboard.data(forType: .html),
           let attributed = NSAttributedString(
               html: htmlData,
               options: [.documentType: NSAttributedString.DocumentType.html],
               documentAttributes: nil)
        {
            return self.normalizeLineEndings(attributed.string)
        }
        return nil
    }

    private func markOwnWrite() {
        let count = self.pasteboard.changeCount
        self.ignoredChangeCounts.insert(count)
        self.lastSeenChangeCount = count
    }

    // MARK: - Helpers

    static func ellipsize(_ text: String, limit: Int) -> String {
        guard limit >= 3, text.count > limit else { return text }
        let keep = limit - 1
        let headCount = keep / 2
        let tailCount = keep - headCount
        return "\(text.prefix(headCount))…\(text.suffix(tailCount))"
    }

    private func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
