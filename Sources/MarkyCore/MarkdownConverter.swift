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

/// Visual theme for the converted rich-text output.
public struct ConvertTheme: Sendable {
    public let bodyFontFamily: String
    public let bodyFontSize: String
    public let bodyColor: String
    public let codeBackground: String
    public let blockquoteBorderColor: String
    public let blockquoteColor: String
    public let tableBorderColor: String
    public let tableHeaderBackground: String
    public let linkColor: String
    public let hrColor: String

    public init(
        bodyFontFamily: String,
        bodyFontSize: String,
        bodyColor: String,
        codeBackground: String,
        blockquoteBorderColor: String,
        blockquoteColor: String,
        tableBorderColor: String,
        tableHeaderBackground: String,
        linkColor: String,
        hrColor: String
    ) {
        self.bodyFontFamily = bodyFontFamily
        self.bodyFontSize = bodyFontSize
        self.bodyColor = bodyColor
        self.codeBackground = codeBackground
        self.blockquoteBorderColor = blockquoteBorderColor
        self.blockquoteColor = blockquoteColor
        self.tableBorderColor = tableBorderColor
        self.tableHeaderBackground = tableHeaderBackground
        self.linkColor = linkColor
        self.hrColor = hrColor
    }

    /// Light theme (default).
    public static let light = ConvertTheme(
        bodyFontFamily: #"-apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif"#,
        bodyFontSize: "13px",
        bodyColor: "#000000",
        codeBackground: "#f2f2f2",
        blockquoteBorderColor: "#c0c0c0",
        blockquoteColor: "#444444",
        tableBorderColor: "#b0b0b0",
        tableHeaderBackground: "#ebebeb",
        linkColor: "#0a4db3",
        hrColor: "#c0c0c0")

    /// Dark theme for dark-mode paste targets.
    public static let dark = ConvertTheme(
        bodyFontFamily: #"-apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif"#,
        bodyFontSize: "13px",
        bodyColor: "#e8e8e8",
        codeBackground: "#2d2d2d",
        blockquoteBorderColor: "#555555",
        blockquoteColor: "#aaaaaa",
        tableBorderColor: "#555555",
        tableHeaderBackground: "#3a3a3a",
        linkColor: "#6db4ff",
        hrColor: "#555555")

    /// Returns a copy of this theme with the body and code font sizes adjusted.
    public func withFontSize(_ px: Int) -> ConvertTheme {
        ConvertTheme(
            bodyFontFamily: self.bodyFontFamily,
            bodyFontSize: "\(px)px",
            bodyColor: self.bodyColor,
            codeBackground: self.codeBackground,
            blockquoteBorderColor: self.blockquoteBorderColor,
            blockquoteColor: self.blockquoteColor,
            tableBorderColor: self.tableBorderColor,
            tableHeaderBackground: self.tableHeaderBackground,
            linkColor: self.linkColor,
            hrColor: self.hrColor)
    }
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
    public func styledHTMLDocument(fragment: String, theme: ConvertTheme = .light) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        body {
            font-family: \(theme.bodyFontFamily);
            font-size: \(theme.bodyFontSize);
            line-height: 1.45;
            color: \(theme.bodyColor);
        }
        h1 { font-size: 22px; } h2 { font-size: 18px; } h3 { font-size: 15px; }
        h4, h5, h6 { font-size: 13px; }
        code, pre {
            font-family: "SF Mono", Menlo, Monaco, monospace;
            font-size: 12px;
            background-color: \(theme.codeBackground);
        }
        pre { padding: 8px; }
        blockquote {
            margin-left: 8px;
            padding-left: 8px;
            border-left: 3px solid \(theme.blockquoteBorderColor);
            color: \(theme.blockquoteColor);
        }
        table { border-collapse: collapse; }
        th, td { border: 1px solid \(theme.tableBorderColor); padding: 4px 8px; }
        th { background-color: \(theme.tableHeaderBackground); }
        a { color: \(theme.linkColor); }
        hr { border: none; border-top: 1px solid \(theme.hrColor); }
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
    public func convert(_ markdown: String, theme: ConvertTheme? = nil, fontSize: Int? = nil) -> ConversionResult? {
        guard let fragment = self.renderHTMLFragment(markdown) else { return nil }
        var resolvedTheme = theme ?? Self.currentTheme()
        if let fontSize {
            resolvedTheme = resolvedTheme.withFontSize(fontSize)
        }
        let html = self.styledHTMLDocument(fragment: fragment, theme: resolvedTheme)
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

    /// Detects whether the app is currently in dark mode and returns the matching theme.
    @MainActor
    private static func currentTheme() -> ConvertTheme {
        guard let app = NSApp else { return .light }
        let appearance = app.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
        return isDark ? .dark : .light
    }
}
