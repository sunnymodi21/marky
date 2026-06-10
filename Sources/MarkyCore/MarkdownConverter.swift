import AppKit
import cmark_gfm
import cmark_gfm_extensions
import Foundation

public struct ConversionResult: Sendable {
    /// The original markdown, preserved verbatim for the plain-text pasteboard representation.
    public let markdown: String
    /// Full styled HTML document for the `public.html` representation.
    public let html: String
    /// RTF data for the `public.rtf` representation.
    public let rtf: Data
}

public struct MarkdownConverter: Sendable {
    public init() {}

    /// Renders GFM markdown to an HTML fragment via cmark-gfm
    /// (tables, strikethrough, autolinks, task lists enabled).
    public func renderHTMLFragment(_ markdown: String) -> String? {
        cmark_gfm_core_extensions_ensure_registered()

        let options: Int32 = 0 // CMARK_OPT_DEFAULT
        guard let parser = cmark_parser_new(options) else { return nil }
        defer { cmark_parser_free(parser) }

        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }

        let utf8 = Array(markdown.utf8)
        utf8.withUnsafeBufferPointer { buffer in
            buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) { pointer in
                cmark_parser_feed(parser, pointer, buffer.count)
            }
        }

        guard let document = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(document) }

        guard let rendered = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser))
        else { return nil }
        defer { free(rendered) }

        return String(cString: rendered)
    }

    /// Wraps an HTML fragment in a minimal styled document tuned for rich-text paste targets.
    public func styledHTMLDocument(fragment: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        body {
            font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif;
            font-size: 13px;
            line-height: 1.45;
            color: #000000;
        }
        h1 { font-size: 22px; } h2 { font-size: 18px; } h3 { font-size: 15px; }
        h4, h5, h6 { font-size: 13px; }
        code, pre {
            font-family: "SF Mono", Menlo, Monaco, monospace;
            font-size: 12px;
            background-color: #f2f2f2;
        }
        pre { padding: 8px; }
        blockquote {
            margin-left: 8px;
            padding-left: 8px;
            border-left: 3px solid #c0c0c0;
            color: #444444;
        }
        table { border-collapse: collapse; }
        th, td { border: 1px solid #b0b0b0; padding: 4px 8px; }
        th { background-color: #ebebeb; }
        a { color: #0a4db3; }
        hr { border: none; border-top: 1px solid #c0c0c0; }
        </style>
        </head>
        <body>
        \(fragment)
        </body>
        </html>
        """
    }

    /// Full pipeline: markdown -> HTML -> NSAttributedString -> RTF.
    ///
    /// Main-actor isolated because AppKit's HTML importer must run on the main thread.
    @MainActor
    public func convert(_ markdown: String) -> ConversionResult? {
        guard let fragment = self.renderHTMLFragment(markdown) else { return nil }
        let html = self.styledHTMLDocument(fragment: fragment)
        guard let htmlData = html.data(using: .utf8) else { return nil }

        guard let attributed = NSAttributedString(
            html: htmlData,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil)
        else { return nil }

        let fullRange = NSRange(location: 0, length: attributed.length)
        guard let rtf = attributed.rtf(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        else { return nil }

        return ConversionResult(markdown: markdown, html: html, rtf: rtf)
    }
}
