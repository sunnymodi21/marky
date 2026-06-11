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
}

/// CopyClip-style clipboard history: most recent first, click to copy back.
/// Records both text and images, persists across launches.
@MainActor
final class ClipboardHistoryStore: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []

    private let settings: AppSettings
    private let storageURL: URL?
    private var thumbnailCache: [UUID: NSImage] = [:]

    /// Skip images larger than this (huge screenshots would bloat the history file).
    static let maxImageBytes = 10 * 1024 * 1024

    init(settings: AppSettings, storageURL: URL? = ClipboardHistoryStore.defaultStorageURL()) {
        self.settings = settings
        self.storageURL = storageURL
        self.load()
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
    func search(_ query: String) -> [ClipboardEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return self.entries }
        return self.entries.filter { entry in
            guard case let .text(text) = entry.content else { return false }
            return text.localizedCaseInsensitiveContains(trimmed)
        }
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
        if let existing = self.entries.firstIndex(where: { $0.content == content }) {
            self.entries.remove(at: existing)
        }
        self.entries.insert(ClipboardEntry(id: UUID(), date: Date(), content: content), at: 0)

        let limit = max(1, self.settings.historyRememberLimit)
        if self.entries.count > limit {
            self.entries.removeLast(self.entries.count - limit)
        }
        self.save()
    }

    func delete(_ entry: ClipboardEntry) {
        self.entries.removeAll { $0.id == entry.id }
        self.thumbnailCache.removeValue(forKey: entry.id)
        self.save()
    }

    func clear() {
        self.entries.removeAll()
        self.thumbnailCache.removeAll()
        self.save()
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
        if let cached = self.thumbnailCache[entry.id] { return cached }
        guard let image = NSImage(data: pngData), image.size.width > 0, image.size.height > 0
        else { return nil }

        let maxSize = NSSize(width: 120, height: 70)
        let scale = min(maxSize.width / image.size.width, maxSize.height / image.size.height, 1)
        let target = NSSize(width: image.size.width * scale, height: image.size.height * scale)

        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        thumb.unlockFocus()

        self.thumbnailCache[entry.id] = thumb
        return thumb
    }

    // MARK: - Persistence

    private struct StoredEntry: Codable {
        let id: UUID
        let date: Date
        let text: String?
        let imageBase64: String?
    }

    private func load() {
        guard let url = self.storageURL,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([StoredEntry].self, from: data)
        else { return }

        self.entries = stored.compactMap { item in
            if let text = item.text {
                return ClipboardEntry(id: item.id, date: item.date, content: .text(text))
            }
            if let base64 = item.imageBase64, let pngData = Data(base64Encoded: base64) {
                return ClipboardEntry(id: item.id, date: item.date, content: .image(pngData: pngData))
            }
            return nil
        }
    }

    private func save() {
        guard let url = self.storageURL else { return }
        let stored = self.entries.map { entry -> StoredEntry in
            switch entry.content {
            case let .text(text):
                StoredEntry(id: entry.id, date: entry.date, text: text, imageBase64: nil)
            case let .image(pngData):
                StoredEntry(
                    id: entry.id,
                    date: entry.date,
                    text: nil,
                    imageBase64: pngData.base64EncodedString())
            }
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
