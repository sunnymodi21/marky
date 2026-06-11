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

    @Test func displayLimitCapsMenuEntries() {
        let settings = self.makeSettings()
        settings.historyDisplayLimit = 5
        let store = ClipboardHistoryStore(settings: settings, storageURL: nil)
        for index in 0..<10 {
            store.recordText("entry \(index)")
        }

        #expect(store.entries.count == 10)
        #expect(store.displayEntries.count == 5)
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

        let reloaded = ClipboardHistoryStore(settings: settings, storageURL: url)
        #expect(reloaded.entries.count == 2)
        #expect(reloaded.entries.map(\.content) == store.entries.map(\.content))
    }

    @Test func restoreWritesTextToPasteboard() {
        let store = ClipboardHistoryStore(settings: self.makeSettings(), storageURL: nil)
        store.recordText("restore me")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("marky-tests-\(UUID().uuidString)"))

        store.restore(store.entries[0], to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "restore me")
    }

    @Test func restoreWritesImageToPasteboard() {
        let store = ClipboardHistoryStore(settings: self.makeSettings(), storageURL: nil)
        store.recordImage(pngData: self.makePNG())
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("marky-tests-\(UUID().uuidString)"))

        store.restore(store.entries[0], to: pasteboard)
        #expect(pasteboard.data(forType: .png) != nil)
        #expect(pasteboard.data(forType: .tiff) != nil)
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

    @Test func searchExcludesImagesAndNonMatches() {
        let store = ClipboardHistoryStore(settings: self.makeSettings(), storageURL: nil)
        store.recordText("alpha")
        store.recordImage(pngData: self.makePNG())

        #expect(store.search("alpha").count == 1)
        #expect(store.search("zzz").isEmpty)
    }
}
