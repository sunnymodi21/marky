import AppKit
import Foundation
@testable import Marky
import Testing

@Suite struct ImageTextRecognizerTests {
    @MainActor
    private func renderTextImage(_ text: String) -> Data? {
        let size = NSSize(width: 600, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(
            at: NSPoint(x: 24, y: 30),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 48, weight: .medium),
                .foregroundColor: NSColor.black,
            ])
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @Test @MainActor func recognizesRenderedText() async throws {
        let png = try #require(self.renderTextImage("Hello Marky 123"))
        let recognized = try await ImageTextRecognizer.recognizeText(pngData: png)
        #expect(recognized.contains("Hello"))
        #expect(recognized.contains("123"))
    }

    @Test func returnsEmptyForBlankImage() async throws {
        let size = NSSize(width: 200, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))

        let recognized = try await ImageTextRecognizer.recognizeText(pngData: png)
        #expect(recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
