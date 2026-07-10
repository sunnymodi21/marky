import AppKit
import Foundation
import MarkyCore

/// Watches the system pasteboard and rewrites Markdown as rich text.
///
/// macOS has no clipboard-change notification API, so we poll `changeCount`
/// every ~150ms, wait a short grace delay for promised pasteboard data, then
/// detect + convert. Pasteboard IO lives in `PasteboardService` (which owns the
/// own-write marker protocol); skip rules live in `ClipboardPolicy`. This class
/// is the polling loop and the convert/capture orchestration.
@MainActor
final class ClipboardMonitor: ObservableObject {
    private let settings: AppSettings
    private let pasteboardService: PasteboardService
    private let policy: ClipboardPolicy
    private let history: ClipboardHistoryStore?
    private let converter = MarkdownConverter()
    private let detector = MarkdownDetector()

    private var timer: DispatchSourceTimer?
    private var lastSeenChangeCount: Int
    private var pendingGrace: DispatchWorkItem?

    private let pollInterval: DispatchTimeInterval = .milliseconds(150)
    private let pollLeeway: DispatchTimeInterval = .milliseconds(50)
    private let graceDelay: DispatchTimeInterval = .milliseconds(80)

    @Published private(set) var convertPulseID: Int = 0
    @Published private(set) var conversionCount: Int = 0
    private(set) var lastConversion: ConversionResult?

    init(
        settings: AppSettings,
        pasteboardService: PasteboardService,
        policy: ClipboardPolicy,
        history: ClipboardHistoryStore? = nil)
    {
        self.settings = settings
        self.pasteboardService = pasteboardService
        self.policy = policy
        self.history = history
        self.lastSeenChangeCount = pasteboardService.changeCount
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
        let current = self.pasteboardService.changeCount
        guard current != self.lastSeenChangeCount else { return }

        if self.pasteboardService.consumeIgnoredChange(current) {
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
            guard observed == self.pasteboardService.changeCount else { return }
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
        self.lastSeenChangeCount = self.pasteboardService.changeCount

        guard self.settings.autoConvertEnabled || force else { return false }

        let alreadyConverted = self.pasteboardService.hasMarker
        if alreadyConverted, !force { return false }
        if self.policy.isSensitive(types: self.pasteboardService.types), !force { return false }
        if !force, self.policy.isFromExcludedApp() { return false }

        guard let markdown = self.pasteboardService.readPlainText(),
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        if !force, self.policy.matchesIgnorePatterns(markdown) { return false }

        if !force {
            guard self.detector.isMarkdown(markdown, config: self.settings.convertConfig) else { return false }
        }

        return self.performConversion(markdown)
    }

    /// Converts arbitrary text to rich text and writes it to the clipboard.
    /// Used by "Copy as Rich Text" from history entries. Always forces conversion.
    @discardableResult
    func convertTextToRichText(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return self.performConversion(text)
    }

    private func performConversion(_ markdown: String) -> Bool {
        guard let result = self.converter.convert(
            markdown,
            theme: .system(),
            fontSize: self.settings.outputFontSize)
        else { return false }

        self.pasteboardService.writeRich(result)
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
        guard !self.pasteboardService.hasMarker,
              !self.policy.isSensitive(types: self.pasteboardService.types),
              !self.policy.isFromExcludedApp()
        else { return }

        if let text = self.pasteboardService.readPlainText() {
            guard !self.policy.matchesIgnorePatterns(text) else { return }
            history.recordText(text)
        } else if let pngData = self.pasteboardService.readImagePNG() {
            history.recordImage(pngData: pngData)
        }
    }
}
