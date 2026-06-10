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
    private let converter = MarkdownConverter()
    private let detector = MarkdownDetector()

    private var timer: DispatchSourceTimer?
    private var lastSeenChangeCount: Int
    private var ignoredChangeCounts: Set<Int> = []

    private let pollInterval: DispatchTimeInterval = .milliseconds(150)
    private let pollLeeway: DispatchTimeInterval = .milliseconds(50)
    private let graceDelay: DispatchTimeInterval = .milliseconds(80)

    @Published private(set) var lastSummary: String = ""
    @Published private(set) var convertPulseID: Int = 0
    @Published private(set) var frontmostAppName: String = "current app"
    private(set) var lastConversion: ConversionResult?

    init(settings: AppSettings, pasteboard: NSPasteboard = .general) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.lastSeenChangeCount = pasteboard.changeCount
        self.updateFrontmostAppName(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(self.handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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

        let observed = current
        // Grace delay lets promised pasteboard data settle before we read/transform.
        DispatchQueue.main.asyncAfter(deadline: .now() + self.graceDelay) { [weak self] in
            guard let self else { return }
            guard observed == self.pasteboard.changeCount else { return }
            self.convertClipboardIfNeeded(force: false)
        }
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

        guard let markdown = self.clipboardMarkdown(),
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        if !force {
            guard self.detector.isMarkdown(markdown, config: self.settings.convertConfig) else { return false }
        }

        guard let result = self.converter.convert(markdown) else {
            if force { self.lastSummary = "Conversion failed." }
            return false
        }

        self.writeRich(result)
        self.lastConversion = result
        self.updateSummary(with: markdown)
        self.convertPulseID &+= 1
        return true
    }

    // MARK: - Pasteboard IO

    var hasMarker: Bool {
        self.pasteboard.types?.contains(Self.markerType) == true
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
        let item = NSPasteboardItem()
        item.setString(markdown, forType: .string)
        item.setData(Data(), forType: Self.markerType)

        self.pasteboard.clearContents()
        self.pasteboard.writeObjects([item])
        self.markOwnWrite()
    }

    private func markOwnWrite() {
        let count = self.pasteboard.changeCount
        self.ignoredChangeCounts.insert(count)
        self.lastSeenChangeCount = count
    }

    // MARK: - Helpers

    private func updateSummary(with markdown: String) {
        let singleLine = markdown
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        self.lastSummary = Self.ellipsize(singleLine, limit: 90)
    }

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

    @objc
    private func handleAppActivation(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        self.updateFrontmostAppName(app)
    }

    private func updateFrontmostAppName(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        self.frontmostAppName = app.localizedName ?? "current app"
    }
}
