import AppKit
import Foundation
@testable import Marky
import Testing

@MainActor
@Suite struct ClipboardHistoryTests {
    private func makeSettings() -> AppSettings {
        let suiteName = "marky-history-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(defaults: defaults)
    }

    private func tempStorageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("marky-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private func makePNG(width: Int = 4, height: Int = 4) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func makeActions(settings: AppSettings, pasteboard: NSPasteboard) -> ClipboardActions {
        let service = PasteboardService(pasteboard: pasteboard)
        let policy = ClipboardPolicy(settings: settings, frontmostBundleID: { nil })
        let monitor = ClipboardMonitor(
            settings: settings,
            pasteboardService: service,
            policy: policy)
        return ClipboardActions(monitor: monitor, pasteboard: service)
    }

    @Test func recordsTextMostRecentFirst() {
        let store = ClipboardHistoryStore(settings: self.makeSettings(), storageURL: nil)
        store.recordText("first")
        store.recordText("second")

        #expect(store.entries.count == 2)
        #expect(store.entries[0].content == .text("second"))
        #expect(store.entries[1].content == .text("first"))
    }

    @Test func dedupesRecopiedContentToTop() {
        let store = ClipboardHistoryStore(settings: self.makeSettings(), storageURL: nil)
        store.recordText("a")
        store.recordText("b")
        store.recordText("a")

        #expect(store.entries.count == 2)
        #expect(store.entries[0].content == .text("a"))
    }

    @Test func pinnedEntriesSortToTopOfSearch() {
        let store = ClipboardHistoryStore(settings: self.makeSettings(), storageURL: nil)
        store.recordText("first")
        store.recordText("second")
        store.recordText("third")

        // Pin the oldest entry; it should jump ahead of newer, unpinned ones.
        let oldest = store.entries.first { $0.content == .text("first") }!
        store.togglePin(oldest)

        let results = store.search("")
        #expect(results.first?.content == .text("first"))
        #expect(results.first?.pinned == true)
        #expect(results.dropFirst().allSatisfy { !$0.pinned })

        // Unpinning restores most-recent-first ordering.
        store.togglePin(store.search("").first!)
        #expect(store.search("").first?.content == .text("third"))
    }

    @Test func enforcesRememberLimit() {
        let settings = self.makeSettings()
        settings.historyRememberLimit = 5
        let store = ClipboardHistoryStore(settings: settings, storageURL: nil)
        for index in 0..<20 {
            store.recordText("entry \(index)")
        }

        #expect(store.entries.count == 5)
        #expect(store.entries[0].content == .text("entry 19"))
    }

    @Test func skipsEmptyText() {
        let store = ClipboardHistoryStore(settings: self.makeSettings(), storageURL: nil)
        store.recordText("   \n  ")
        #expect(store.entries.isEmpty)
    }

    @Test func recordsImageWithThumbnailAndTitle() {
        let store = ClipboardHistoryStore(settings: self.makeSettings(), storageURL: nil)
        store.recordImage(pngData: self.makePNG(width: 8, height: 6))

        #expect(store.entries.count == 1)
        guard let entry = store.entries.first else { return }
        #expect(store.thumbnail(for: entry) != nil)
        #expect(store.title(for: entry) == "Image (8 × 6)")
    }

    @Test func skipsOversizedImages() {
        let store = ClipboardHistoryStore(settings: self.makeSettings(), storageURL: nil)
        let huge = Data(count: ClipboardHistoryStore.maxImageBytes + 1)
        store.recordImage(pngData: huge)
        #expect(store.entries.isEmpty)
    }

    @Test func persistsAcrossLaunches() {
        let settings = self.makeSettings()
        let url = self.tempStorageURL()

        let store = ClipboardHistoryStore(settings: settings, storageURL: url)
        store.recordText("persisted text")
        store.recordImage(pngData: self.makePNG())
        store.flushPendingSave()

        let reloaded = ClipboardHistoryStore(settings: settings, storageURL: url)
        #expect(reloaded.entries.count == 2)
        #expect(reloaded.entries.map(\.content) == store.entries.map(\.content))
    }

    @Test func restoreWritesTextToPasteboard() {
        let settings = self.makeSettings()
        let store = ClipboardHistoryStore(settings: settings, storageURL: nil)
        store.recordText("restore me")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("marky-tests-\(UUID().uuidString)"))
        let actions = self.makeActions(settings: settings, pasteboard: pasteboard)

        #expect(actions.restore(store.entries[0], from: store))
        #expect(pasteboard.string(forType: .string) == "restore me")
        #expect(pasteboard.types?.contains(PasteboardService.markerType) == true)
    }

    @Test func restoreWritesImageToPasteboard() {
        let settings = self.makeSettings()
        let store = ClipboardHistoryStore(settings: settings, storageURL: nil)
        store.recordImage(pngData: self.makePNG())
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("marky-tests-\(UUID().uuidString)"))
        let actions = self.makeActions(settings: settings, pasteboard: pasteboard)

        #expect(actions.restore(store.entries[0], from: store))
        #expect(pasteboard.data(forType: .png) != nil)
        #expect(pasteboard.data(forType: .tiff) != nil)
        #expect(pasteboard.types?.contains(PasteboardService.markerType) == true)
    }

    @Test func clearEmptiesStoreAndDisk() {
        let settings = self.makeSettings()
        let url = self.tempStorageURL()
        let store = ClipboardHistoryStore(settings: settings, storageURL: url)
        store.recordText("something")
        store.clear()

        #expect(store.entries.isEmpty)
        let reloaded = ClipboardHistoryStore(settings: settings, storageURL: url)
        #expect(reloaded.entries.isEmpty)
    }

    @Test func deleteRemovesSingleEntryAndPersists() {
        let settings = self.makeSettings()
        let url = self.tempStorageURL()
        let store = ClipboardHistoryStore(settings: settings, storageURL: url)
        store.recordText("keep me")
        store.recordText("delete me")

        let target = store.entries.first { entry in
            if case let .text(text) = entry.content { return text == "delete me" }
            return false
        }!
        store.delete(target)
        store.flushPendingSave()

        #expect(store.entries.count == 1)
        #expect(!store.entries.contains { $0.id == target.id })

        let reloaded = ClipboardHistoryStore(settings: settings, storageURL: url)
        #expect(reloaded.entries.count == 1)
    }

    @Test func searchFindsCaseInsensitiveSubstrings() {
        let store = ClipboardHistoryStore(settings: self.makeSettings(), storageURL: nil)
        store.recordText("# Meeting Notes for Q3")
        store.recordText("grocery list: milk, eggs")
        store.recordText("MEETING follow-up tasks")

        let results = store.search("meeting")
        #expect(results.count == 2)
        #expect(results.allSatisfy { entry in
            guard case let .text(text) = entry.content else { return false }
            return text.localizedCaseInsensitiveContains("meeting")
        })
    }

    @Test func emptySearchReturnsEverythingIncludingImages() {
        let store = ClipboardHistoryStore(settings: self.makeSettings(), storageURL: nil)
        store.recordText("some text")
        store.recordImage(pngData: self.makePNG())

        #expect(store.search("").count == 2)
        #expect(store.search("   ").count == 2)
    }

    @Test func marksMarkdownTextAtRecordTime() {
        let store = ClipboardHistoryStore(settings: self.makeSettings(), storageURL: nil)
        store.recordText("# Title\n\n**bold** text\n\n- a\n- b")
        store.recordText("plain sentence, no markup")

        #expect(store.entries.first { $0.content == .text("# Title\n\n**bold** text\n\n- a\n- b") }?.isMarkdown == true)
        #expect(store.entries.first { $0.content == .text("plain sentence, no markup") }?.isMarkdown == false)
    }

    @Test func dedupesRecopiedImagesByHash() {
        let store = ClipboardHistoryStore(settings: self.makeSettings(), storageURL: nil)
        let png = self.makePNG()
        store.recordImage(pngData: png)
        store.recordText("in between")
        store.recordImage(pngData: png)

        #expect(store.entries.count == 2)
        if case .image = store.entries[0].content {} else {
            Issue.record("expected the re-copied image at the top")
        }
    }

    @Test func imageBytesRoundTripAcrossReload() {
        let settings = self.makeSettings()
        let url = self.tempStorageURL()
        let png = self.makePNG(width: 8, height: 6)

        let store = ClipboardHistoryStore(settings: settings, storageURL: url)
        store.recordImage(pngData: png)
        store.flushPendingSave()

        let reloaded = ClipboardHistoryStore(settings: settings, storageURL: url)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.pngData(for: reloaded.entries[0]) == png)
        #expect(reloaded.title(for: reloaded.entries[0]) == "Image (8 × 6)")
        #expect(reloaded.thumbnail(for: reloaded.entries[0]) != nil)
    }

    @Test func searchExcludesImagesAndNonMatches() {
        let store = ClipboardHistoryStore(settings: self.makeSettings(), storageURL: nil)
        store.recordText("alpha")
        store.recordImage(pngData: self.makePNG())

        #expect(store.search("alpha").count == 1)
        #expect(store.search("zzz").isEmpty)
    }
}
