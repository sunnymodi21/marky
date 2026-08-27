import AppKit
import Foundation
import MarkyCore

let usage = """
USAGE: marky [options] [file | -]

Converts Markdown to rich text (RTF + HTML) and writes it to the clipboard,
keeping the original Markdown as the plain-text representation.

INPUT:
  (none)      read Markdown from the clipboard
  -           read Markdown from stdin
  <file>      read Markdown from a file

OPTIONS:
  --html      print the generated HTML to stdout instead of writing the clipboard
  --detect    print the detection score and exit (0 = looks like markdown, 2 = not markdown)
  -h, --help  show this help

EXIT CODES: 0 ok · 1 no input/error · 2 not markdown / conversion failed
"""

var printHTML = false
var detectOnly = false
var inputSource: String?

for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "--html": printHTML = true
    case "--detect": detectOnly = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        inputSource = argument
    }
}

@MainActor
func readInput() -> String? {
    switch inputSource {
    case "-":
        guard let data = try? FileHandle.standardInput.readToEnd(), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    case let path?:
        return try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
    case nil:
        return NSPasteboard.general.string(forType: .string)
    }
}

guard let markdown = readInput(), !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    FileHandle.standardError.write(Data("marky: no input\n".utf8))
    exit(1)
}

if detectOnly {
    let detector = MarkdownDetector()
    let config = ConvertConfig()
    let score = detector.score(markdown, config: config)
    let isMarkdown = score >= config.scoreThreshold
    print("score=\(score) markdown=\(isMarkdown)")
    exit(isMarkdown ? 0 : 2)
}

let converter = MarkdownConverter()
guard let result = converter.convert(markdown) else {
    FileHandle.standardError.write(Data("marky: conversion failed\n".utf8))
    exit(2)
}

if printHTML {
    print(result.html)
    exit(0)
}

let item = NSPasteboardItem()
item.setData(result.rtf, forType: .rtf)
item.setString(result.html, forType: .html)
item.setString(result.markdown, forType: .string)
item.setData(Data(), forType: NSPasteboard.PasteboardType("com.sunnymodi.marky"))

let pasteboard = NSPasteboard.general
pasteboard.clearContents()
guard pasteboard.writeObjects([item]) else {
    FileHandle.standardError.write(Data("marky: failed to write clipboard\n".utf8))
    exit(2)
}

print("Rich text copied to clipboard (\(result.rtf.count) bytes RTF).")
exit(0)
