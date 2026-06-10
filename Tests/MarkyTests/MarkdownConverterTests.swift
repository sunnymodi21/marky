import Foundation
import MarkyCore
import Testing

@Suite struct MarkdownConverterTests {
    let converter = MarkdownConverter()

    @Test func rendersBasicHTMLFragment() {
        let fragment = self.converter.renderHTMLFragment("# Title\n\n**bold** and *italic* and [link](https://x.com)")
        #expect(fragment != nil)
        let html = fragment ?? ""
        #expect(html.contains("<h1>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>italic</em>"))
        #expect(html.contains(#"<a href="https://x.com">link</a>"#))
    }

    @Test func rendersGFMTable() {
        let markdown = """
        | a | b |
        |---|---|
        | 1 | 2 |
        """
        let html = self.converter.renderHTMLFragment(markdown) ?? ""
        #expect(html.contains("<table>"))
        #expect(html.contains("<td>1</td>"))
    }

    @Test func rendersStrikethroughAndTaskList() {
        let html = self.converter.renderHTMLFragment("~~gone~~\n\n- [x] done") ?? ""
        #expect(html.contains("<del>gone</del>"))
        #expect(html.contains("checked"))
    }

    @Test @MainActor func convertProducesRTFAndHTML() {
        let result = self.converter.convert("# Hello\n\nSome **bold** text.")
        #expect(result != nil)
        guard let result else { return }

        #expect(result.markdown == "# Hello\n\nSome **bold** text.")
        #expect(result.html.contains("<h1>"))
        #expect(!result.rtf.isEmpty)

        let rtfPrefix = String(data: result.rtf.prefix(6), encoding: .ascii)
        #expect(rtfPrefix == "{\\rtf1")
    }

    @Test @MainActor func convertPreservesOriginalMarkdownVerbatim() {
        let markdown = "- item one\n- item two\n\n> quote"
        let result = self.converter.convert(markdown)
        #expect(result?.markdown == markdown)
    }
}
