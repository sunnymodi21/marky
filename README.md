# Marky

> Copy Markdown, paste rich text. A tiny macOS menu-bar app that watches your clipboard and rewrites Markdown as formatted rich text — while keeping the raw Markdown for plain-text apps.

## What it does

You copy this:

```markdown
# Status update

**Done:** shipped the *parser*.

- Fixed [the bug](https://example.com)
- Added tests
```

Marky rewrites your clipboard so that:

- **Rich-text apps** (Mail, Notes, Pages, Word, Slack, Google Docs) paste formatted text — real headings, bold, links, lists, tables.
- **Plain-text apps** (editors, terminals) still paste the original raw Markdown, untouched.

No destructive conversion: the original Markdown is always preserved as the plain-text representation on the pasteboard.

## Features

- Lives in your menu bar. No Dock icon (`LSUIElement`). macOS 15+.
- Watches the clipboard (~150 ms polling) and auto-converts when text looks like Markdown.
- Score-based Markdown detection. Shell commands, source code, and bare URLs are left alone.
- Global hotkeys: **Paste as Rich Text** (⌥⌘M) and **Paste Original Markdown** (⌥⇧⌘M). Synthetic paste requires the Accessibility permission.
- GFM support via cmark-gfm: tables, strikethrough, task lists, autolinks.
- Marker pasteboard type (`com.sunnymodi.marky`) prevents Marky from reprocessing its own writes.
- Headless CLI for scripts: `pbpaste | marky -`.

### Clipboard history (CopyClip-style)

- Records everything you copy — **text and images** — most recent first.
- Click an entry in the menu to copy it back (re-copied items move to the top instead of duplicating).
- Image entries show inline thumbnails; TIFF copies (screenshots, Preview) are stored as PNG.
- Separate **remember** (default 50, up to 500) and **display** (default 15) limits, configurable in Settings → History.
- History persists across launches (`~/Library/Application Support/Marky/history.json`).
- Content marked confidential/transient by password managers (`org.nspasteboard.ConcealedType` / `TransientType`) is never recorded or converted.
- Images larger than 10 MB are skipped to keep the history file small.

## Build

Swift 6, macOS 15+:

```sh
swift build -c release
./Scripts/package_app.sh release   # → Marky.app
```

Dev loop (kills running instance, builds, tests, relaunches):

```sh
./Scripts/compile_and_run.sh
```

Run tests:

```sh
swift test
```

## CLI

```sh
# Convert clipboard markdown to rich text in place
swift run MarkyCLI

# Convert stdin and copy to clipboard
pbpaste | swift run MarkyCLI -

# Print generated HTML instead of writing the clipboard
swift run MarkyCLI --html -
```

Exit codes: `0` ok · `1` no input · `2` conversion failed.

## How it works

1. A `DispatchSourceTimer` polls `NSPasteboard.general.changeCount` every ~150 ms (there is no clipboard-change notification API on macOS).
2. After a change, an 80 ms grace delay lets promised pasteboard data settle.
3. `MarkdownDetector` scores the text (headings, emphasis, links, lists, fences, tables vs. shell/source-code/URL negatives).
4. `MarkdownConverter` renders Markdown → HTML (cmark-gfm) → `NSAttributedString` → RTF.
5. A single `NSPasteboardItem` is written with `public.rtf`, `public.html`, the original Markdown as `public.utf8-plain-text`, and the Marky marker type.

## License

MIT
