import AppKit
import Foundation

enum ClipboardContent: Equatable {
    case text(String)
    case image(pngData: Data)
}

struct ClipboardEntry: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let content: ClipboardContent
    var pinned: Bool = false
}

/// CopyClip-style clipboard history: most recent first, click to copy back.
/// Records both text and images, persists across launches.
/// Images are stored as individual PNG files (not base64 in JSON) for efficiency.
@MainActor
final class ClipboardHistoryStore: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []

    private let settings: AppSettings
    private let storageURL: URL?
    private let imageDirectory: URL?
    private let thumbnailCache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 30
        return cache
    }()
    private var pendingSave: DispatchWorkItem?

    /// Skip images larger than this (huge screenshots would bloat the history file).
    static let maxImageBytes = 10 * 1024 * 1024

    init(settings: AppSettings, storageURL: URL? = ClipboardHistoryStore.defaultStorageURL()) {
        self.settings = settings
        self.storageURL = storageURL
        self.imageDirectory = storageURL?.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
        if let dir = self.imageDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        self.insert(.text(text))
    }

    func recordImage(pngData: Data) {
        guard !pngData.isEmpty, pngData.count <= Self.maxImageBytes else { return }
        self.insert(.image(pngData: pngData))
    }

    private func insert(_ content: ClipboardContent) {
        // Re-copied content moves to the top instead of duplicating.
        var preservedPin = false
        if let existing = self.entries.firstIndex(where: { $0.content == content }) {
            preservedPin = self.entries[existing].pinned
            let removed = self.entries.remove(at: existing)
            self.deleteImageFile(for: removed.id)
        }
        let entry = ClipboardEntry(id: UUID(), date: Date(), content: content, pinned: preservedPin)
        if case .image = content {
            self.writeImageFile(for: entry)
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
                self.deleteImageFile(for: entry.id)
                self.thumbnailCache.removeObject(forKey: entry.id as NSUUID)
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
        self.deleteImageFile(for: entry.id)
        self.thumbnailCache.removeObject(forKey: entry.id as NSUUID)
        self.save()
    }

    func clear() {
        for entry in self.entries {
            self.deleteImageFile(for: entry.id)
        }
        self.entries.removeAll()
        self.thumbnailCache.removeAllObjects()
        self.saveNow()
    }

    // MARK: - Restore (click-to-copy)

    /// Writes a history entry back to the pasteboard. The monitor observes the
    /// change like any other copy, so the entry moves to the top of the history
    /// and markdown text gets auto-converted as usual.
    func restore(_ entry: ClipboardEntry, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        switch entry.content {
        case let .text(text):
            pasteboard.setString(text, forType: .string)
        case let .image(pngData):
            pasteboard.setData(pngData, forType: .png)
            if let tiff = NSBitmapImageRep(data: pngData)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        }
    }

    // MARK: - Display helpers

    func title(for entry: ClipboardEntry) -> String {
        switch entry.content {
        case let .text(text):
            let firstLine = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            return ClipboardMonitor.ellipsize(firstLine, limit: 60)
        case let .image(pngData):
            if let rep = NSBitmapImageRep(data: pngData) {
                return "Image (\(rep.pixelsWide) × \(rep.pixelsHigh))"
            }
            return "Image"
        }
    }

    func thumbnail(for entry: ClipboardEntry) -> NSImage? {
        guard case let .image(pngData) = entry.content else { return nil }
        let key = entry.id as NSUUID
        if let cached = self.thumbnailCache.object(forKey: key) { return cached }
        guard let image = NSImage(data: pngData), image.size.width > 0, image.size.height > 0
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
        /// New format: filename of image stored in the images directory.
        let imageFilename: String?
        /// Legacy format: base64-encoded image data inline in JSON.
        /// Kept for migration; new writes always use imageFilename.
        let imageBase64: String?
    }

    private func load() {
        guard let url = self.storageURL,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([StoredEntry].self, from: data)
        else { return }

        var needsResave = false
        self.entries = stored.compactMap { item in
            let isPinned = item.pinned ?? false
            if let text = item.text {
                return ClipboardEntry(id: item.id, date: item.date, content: .text(text), pinned: isPinned)
            }
            // New format: load from file.
            if let filename = item.imageFilename, let dir = self.imageDirectory {
                let fileURL = dir.appendingPathComponent(filename)
                if let pngData = try? Data(contentsOf: fileURL) {
                    return ClipboardEntry(id: item.id, date: item.date, content: .image(pngData: pngData), pinned: isPinned)
                }
                return nil
            }
            // Legacy format: migrate base64 to file storage.
            if let base64 = item.imageBase64, let pngData = Data(base64Encoded: base64) {
                let entry = ClipboardEntry(id: item.id, date: item.date, content: .image(pngData: pngData), pinned: isPinned)
                self.writeImageFile(for: entry)
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
    /// into a single JSON write after 500ms of quiet. Image files are written immediately
    /// in `writeImageFile`; only the JSON metadata is debounced.
    private func save() {
        self.pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performSave()
        }
        self.pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Flushes any pending save immediately. Called on clear() and app termination.
    private func saveNow() {
        self.pendingSave?.cancel()
        self.pendingSave = nil
        self.performSave()
    }

    private func performSave() {
        guard let url = self.storageURL else { return }
        let stored = self.entries.map { entry -> StoredEntry in
            switch entry.content {
            case let .text(text):
                StoredEntry(id: entry.id, date: entry.date, text: text, pinned: entry.pinned, imageFilename: nil, imageBase64: nil)
            case .image:
                StoredEntry(
                    id: entry.id,
                    date: entry.date,
                    text: nil,
                    pinned: entry.pinned,
                    imageFilename: Self.imageFilename(for: entry.id),
                    imageBase64: nil)
            }
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Flushes any pending debounced save. Call on app termination.
    func flushPendingSave() {
        self.saveNow()
    }

    // MARK: - Image file management

    private static func imageFilename(for id: UUID) -> String {
        "\(id.uuidString).png"
    }

    private func writeImageFile(for entry: ClipboardEntry) {
        guard let dir = self.imageDirectory,
              case let .image(pngData) = entry.content
        else { return }
        let fileURL = dir.appendingPathComponent(Self.imageFilename(for: entry.id))
        try? pngData.write(to: fileURL, options: .atomic)
    }

    private func deleteImageFile(for id: UUID) {
        guard let dir = self.imageDirectory else { return }
        let fileURL = dir.appendingPathComponent(Self.imageFilename(for: id))
        try? FileManager.default.removeItem(at: fileURL)
    }
}
