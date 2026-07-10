import AppKit
import CryptoKit
import Foundation
import MarkyCore
import os

private let historyLogger = Logger(subsystem: "com.sunnymodi.marky", category: "history")

/// Lightweight description of a stored image; the PNG bytes themselves live on
/// disk (or in the in-memory fallback) and are loaded lazily on demand.
struct ImageMeta: Equatable {
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    /// SHA-256 of the PNG data; used for dedup instead of comparing raw bytes.
    let contentHash: String
}

enum ClipboardContent: Equatable {
    case text(String)
    case image(ImageMeta)
}

struct ClipboardEntry: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let content: ClipboardContent
    var pinned: Bool = false
    /// Whether the text scores as Markdown, computed once at record time so the
    /// UI never re-runs detection per render. Always false for images.
    var isMarkdown: Bool = false
}

/// CopyClip-style clipboard history: most recent first, click to copy back.
/// Records both text and images, persists across launches.
/// Image PNGs are stored as individual files and loaded lazily — only small
/// metadata is kept in memory. File IO runs on a background queue.
@MainActor
final class ClipboardHistoryStore: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []

    private let settings: AppSettings
    private let detector = MarkdownDetector()
    private let storageURL: URL?
    private let imageDirectory: URL?

    /// Serializes all file writes/deletes so a delete can never race a pending write.
    private let ioQueue = DispatchQueue(label: "com.sunnymodi.marky.history-io", qos: .utility)

    private let thumbnailCache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 30
        return cache
    }()

    /// Recently touched PNG bytes, so scrolling doesn't re-read files constantly.
    private let imageDataCache: NSCache<NSUUID, NSData> = {
        let cache = NSCache<NSUUID, NSData>()
        cache.totalCostLimit = 50 * 1024 * 1024
        return cache
    }()

    /// Backing bytes when there is no storage directory (memory-only stores, tests).
    /// A plain dictionary, not NSCache: nothing else retains these bytes.
    private var inMemoryImages: [UUID: Data] = [:]

    private var pendingSave: DispatchWorkItem?

    /// Skip images larger than this (huge screenshots would bloat the history).
    static let maxImageBytes = 10 * 1024 * 1024

    init(settings: AppSettings, storageURL: URL? = ClipboardHistoryStore.defaultStorageURL()) {
        self.settings = settings
        self.storageURL = storageURL
        self.imageDirectory = storageURL?.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
        if let dir = self.imageDirectory {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                historyLogger.error("Failed to create image directory: \(error.localizedDescription)")
            }
        }
        self.load()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveNow()
            }
        }
    }

    static func defaultStorageURL() -> URL? {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base
            .appendingPathComponent("Marky", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    /// Entries shown in the menu (CopyClip's "display" limit vs "remember" limit).
    var displayEntries: [ClipboardEntry] {
        Array(self.entries.prefix(max(1, self.settings.historyDisplayLimit)))
    }

    /// Case-insensitive substring search over text entries.
    /// An empty query returns the full history (images included).
    /// Pinned entries always sort to the top of the results.
    func search(_ query: String) -> [ClipboardEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matches: [ClipboardEntry]
        if trimmed.isEmpty {
            matches = self.entries
        } else {
            matches = self.entries.filter { entry in
                guard case let .text(text) = entry.content else { return false }
                return text.localizedCaseInsensitiveContains(trimmed)
            }
        }
        return matches.sorted(by: Self.pinnedThenRecent)
    }

    /// Ordering for history: pinned entries first, then most recent.
    private static func pinnedThenRecent(_ a: ClipboardEntry, _ b: ClipboardEntry) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        return a.date > b.date
    }

    // MARK: - Recording

    func recordText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let isMarkdown = self.detector.isMarkdown(text, config: self.settings.convertConfig)
        self.insert(.text(text), isMarkdown: isMarkdown, pngData: nil)
    }

    func recordImage(pngData: Data) {
        guard !pngData.isEmpty, pngData.count <= Self.maxImageBytes else { return }
        self.insert(.image(Self.imageMeta(for: pngData)), isMarkdown: false, pngData: pngData)
    }

    private static func imageMeta(for pngData: Data) -> ImageMeta {
        let rep = NSBitmapImageRep(data: pngData)
        let digest = SHA256.hash(data: pngData)
        return ImageMeta(
            pixelWidth: rep?.pixelsWide ?? 0,
            pixelHeight: rep?.pixelsHigh ?? 0,
            byteCount: pngData.count,
            contentHash: digest.map { String(format: "%02x", $0) }.joined())
    }

    private func insert(_ content: ClipboardContent, isMarkdown: Bool, pngData: Data?) {
        // Re-copied content moves to the top instead of duplicating.
        // Images compare by metadata (hash), so no byte blobs are compared or loaded.
        var preservedPin = false
        if let existing = self.entries.firstIndex(where: { $0.content == content }) {
            preservedPin = self.entries[existing].pinned
            let removed = self.entries.remove(at: existing)
            self.discardImageStorage(for: removed.id)
        }
        let entry = ClipboardEntry(
            id: UUID(),
            date: Date(),
            content: content,
            pinned: preservedPin,
            isMarkdown: isMarkdown)
        if let pngData {
            self.storeImageData(pngData, for: entry.id)
        }
        self.entries.insert(entry, at: 0)

        self.enforceLimit()
        self.save()
    }

    private func enforceLimit() {
        let limit = max(1, self.settings.historyRememberLimit)
        if self.entries.count > limit {
            let surplus = self.entries.count - limit
            let removed = Array(self.entries.suffix(surplus))
            self.entries.removeLast(surplus)
            for entry in removed {
                self.discardImageStorage(for: entry.id)
            }
        }
    }

    /// Toggles the pinned state of an entry. Pinned entries sort to the top.
    func togglePin(_ entry: ClipboardEntry) {
        guard let index = self.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        self.entries[index].pinned.toggle()
        self.sortEntries()
        self.save()
    }

    private func sortEntries() {
        self.entries.sort(by: Self.pinnedThenRecent)
    }

    func delete(_ entry: ClipboardEntry) {
        self.entries.removeAll { $0.id == entry.id }
        self.discardImageStorage(for: entry.id)
        self.save()
    }

    func clear() {
        for entry in self.entries {
            self.discardImageStorage(for: entry.id)
        }
        self.entries.removeAll()
        self.saveNow()
    }

    // MARK: - Restore (click-to-copy)

    /// Writes a history entry back to the pasteboard. The monitor observes the
    /// change like any other copy, so the entry moves to the top of the history
    /// and markdown text gets auto-converted as usual.
    func restore(_ entry: ClipboardEntry, to pasteboard: NSPasteboard) {
        switch entry.content {
        case let .text(text):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .image:
            guard let pngData = self.pngData(for: entry) else {
                historyLogger.error("Missing image data for history entry \(entry.id)")
                return
            }
            pasteboard.clearContents()
            pasteboard.setData(pngData, forType: .png)
            if let tiff = NSBitmapImageRep(data: pngData)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        }
    }

    // MARK: - Image data access

    /// The PNG bytes for an image entry, loaded lazily from cache, disk, or the
    /// in-memory fallback.
    func pngData(for entry: ClipboardEntry) -> Data? {
        guard case .image = entry.content else { return nil }
        if let data = self.inMemoryImages[entry.id] { return data }
        let key = entry.id as NSUUID
        if let cached = self.imageDataCache.object(forKey: key) { return cached as Data }
        guard let dir = self.imageDirectory else { return nil }
        let fileURL = dir.appendingPathComponent(Self.imageFilename(for: entry.id))
        guard let data = try? Data(contentsOf: fileURL) else {
            historyLogger.error("Failed to read image file for history entry \(entry.id)")
            return nil
        }
        self.imageDataCache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    // MARK: - Display helpers

    func title(for entry: ClipboardEntry) -> String {
        switch entry.content {
        case let .text(text):
            let firstLine = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            return firstLine.ellipsized(limit: 60)
        case let .image(meta):
            guard meta.pixelWidth > 0, meta.pixelHeight > 0 else { return "Image" }
            return "Image (\(meta.pixelWidth) × \(meta.pixelHeight))"
        }
    }

    func thumbnail(for entry: ClipboardEntry) -> NSImage? {
        guard case .image = entry.content else { return nil }
        let key = entry.id as NSUUID
        if let cached = self.thumbnailCache.object(forKey: key) { return cached }
        guard let pngData = self.pngData(for: entry),
              let image = NSImage(data: pngData), image.size.width > 0, image.size.height > 0
        else { return nil }

        let maxSize = NSSize(width: 120, height: 70)
        let scale = min(maxSize.width / image.size.width, maxSize.height / image.size.height, 1)
        let target = NSSize(width: image.size.width * scale, height: image.size.height * scale)

        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        thumb.unlockFocus()

        self.thumbnailCache.setObject(thumb, forKey: key)
        return thumb
    }

    // MARK: - Persistence

    private struct StoredEntry: Codable {
        let id: UUID
        let date: Date
        let text: String?
        let pinned: Bool?
        /// Filename of the PNG stored in the images directory.
        let imageFilename: String?
        let imageWidth: Int?
        let imageHeight: Int?
        let imageByteCount: Int?
        let imageHash: String?
        /// Legacy format: base64-encoded image data inline in JSON.
        /// Kept for migration; new writes always use imageFilename.
        let imageBase64: String?
    }

    private func load() {
        guard let url = self.storageURL else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let stored: [StoredEntry]
        do {
            stored = try JSONDecoder().decode([StoredEntry].self, from: data)
        } catch {
            historyLogger.error("Failed to decode history file: \(error.localizedDescription)")
            return
        }

        var needsResave = false
        self.entries = stored.compactMap { item in
            let isPinned = item.pinned ?? false
            if let text = item.text {
                // Recompute rather than persist the flag so detector improvements
                // apply to old entries.
                let isMarkdown = self.detector.isMarkdown(text, config: self.settings.convertConfig)
                return ClipboardEntry(
                    id: item.id, date: item.date, content: .text(text),
                    pinned: isPinned, isMarkdown: isMarkdown)
            }
            if let filename = item.imageFilename, let dir = self.imageDirectory {
                let fileURL = dir.appendingPathComponent(filename)
                // Metadata present: the bytes stay on disk until actually needed.
                if let width = item.imageWidth, let height = item.imageHeight,
                   let byteCount = item.imageByteCount, let hash = item.imageHash
                {
                    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
                    let meta = ImageMeta(
                        pixelWidth: width, pixelHeight: height,
                        byteCount: byteCount, contentHash: hash)
                    return ClipboardEntry(id: item.id, date: item.date, content: .image(meta), pinned: isPinned)
                }
                // Older file-backed format without metadata: read once to compute it.
                guard let pngData = try? Data(contentsOf: fileURL) else { return nil }
                needsResave = true
                return ClipboardEntry(
                    id: item.id, date: item.date,
                    content: .image(Self.imageMeta(for: pngData)), pinned: isPinned)
            }
            // Legacy format: migrate base64 to file storage.
            if let base64 = item.imageBase64, let pngData = Data(base64Encoded: base64) {
                let entry = ClipboardEntry(
                    id: item.id, date: item.date,
                    content: .image(Self.imageMeta(for: pngData)), pinned: isPinned)
                self.storeImageData(pngData, for: entry.id)
                needsResave = true
                return entry
            }
            return nil
        }
        // Sort loaded entries: pinned first, then by date.
        self.sortEntries()
        if needsResave {
            self.save()
        }
    }

    /// Debounced save: coalesces rapid writes (e.g. multiple copies in quick succession)
    /// into a single JSON write after 500ms of quiet. Image files are written as they
    /// are recorded; only the JSON metadata is debounced.
    private func save() {
        self.pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performSave(synchronous: false)
        }
        self.pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Flushes any pending save immediately. Called on clear() and app termination.
    private func saveNow() {
        self.pendingSave?.cancel()
        self.pendingSave = nil
        self.performSave(synchronous: true)
    }

    /// Encodes on the main actor (entries are main-actor state), writes on the IO
    /// queue. `synchronous` waits for the write — used at termination and in tests.
    private func performSave(synchronous: Bool) {
        guard let url = self.storageURL else { return }
        let stored = self.entries.map { entry -> StoredEntry in
            switch entry.content {
            case let .text(text):
                StoredEntry(
                    id: entry.id, date: entry.date, text: text, pinned: entry.pinned,
                    imageFilename: nil, imageWidth: nil, imageHeight: nil,
                    imageByteCount: nil, imageHash: nil, imageBase64: nil)
            case let .image(meta):
                StoredEntry(
                    id: entry.id, date: entry.date, text: nil, pinned: entry.pinned,
                    imageFilename: Self.imageFilename(for: entry.id),
                    imageWidth: meta.pixelWidth, imageHeight: meta.pixelHeight,
                    imageByteCount: meta.byteCount, imageHash: meta.contentHash,
                    imageBase64: nil)
            }
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(stored)
        } catch {
            historyLogger.error("Failed to encode history: \(error.localizedDescription)")
            return
        }
        let write: @Sendable () -> Void = {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                historyLogger.error("Failed to write history file: \(error.localizedDescription)")
            }
        }
        if synchronous {
            self.ioQueue.sync(execute: write)
        } else {
            self.ioQueue.async(execute: write)
        }
    }

    /// Flushes any pending debounced save. Call on app termination.
    func flushPendingSave() {
        self.saveNow()
    }

    // MARK: - Image file management

    private static func imageFilename(for id: UUID) -> String {
        "\(id.uuidString).png"
    }

    /// Persists PNG bytes for a new entry: to disk (off the main thread) when a
    /// storage directory exists, otherwise to the in-memory fallback.
    private func storeImageData(_ pngData: Data, for id: UUID) {
        guard let dir = self.imageDirectory else {
            self.inMemoryImages[id] = pngData
            return
        }
        self.imageDataCache.setObject(pngData as NSData, forKey: id as NSUUID, cost: pngData.count)
        let fileURL = dir.appendingPathComponent(Self.imageFilename(for: id))
        self.ioQueue.async {
            do {
                try pngData.write(to: fileURL, options: .atomic)
            } catch {
                historyLogger.error("Failed to write image file: \(error.localizedDescription)")
            }
        }
    }

    /// Removes every stored copy of an entry's image bytes (file, caches, fallback).
    private func discardImageStorage(for id: UUID) {
        self.inMemoryImages[id] = nil
        self.thumbnailCache.removeObject(forKey: id as NSUUID)
        self.imageDataCache.removeObject(forKey: id as NSUUID)
        guard let dir = self.imageDirectory else { return }
        let fileURL = dir.appendingPathComponent(Self.imageFilename(for: id))
        self.ioQueue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
