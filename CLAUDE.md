# Marky

macOS menu-bar app (Swift 6, macOS 15+, SwiftPM) that watches the clipboard and rewrites
Markdown as rich text, with a CopyClip-style clipboard history.

## Core behavior

- Polls `NSPasteboard.general.changeCount` every ~150ms (no clipboard notification API
  exists on macOS), with a 50ms leeway and an 80ms grace delay for promised pasteboard data.
- When copied text scores as Markdown, rewrites the pasteboard as a **single
  `NSPasteboardItem`** with multiple representations:
  - `public.rtf` — converted rich text
  - `public.html` — styled HTML (better for Google Docs/Slack)
  - `public.utf8-plain-text` — **the original Markdown, unchanged** (plain-text apps are
    never affected; conversion is non-destructive)
  - `com.sunnymodi.marky` — marker type so the monitor never reprocesses its own writes
- Clipboard history records text and images (PNG; TIFF screenshots converted), persists to
  `~/Library/Application Support/Marky/history.json`, skips content with nspasteboard.org
  concealed/transient types (password managers).
- Image history entries have an OCR action (Vision `VNRecognizeTextRequest`, on-device)
  that copies recognized text to the clipboard.
- The **open-history hotkey opens a standalone floating window** (`HistoryPanelController`,
  a `NSPanel`), separate from the menu-bar dropdown. Picking a clip restores it to the
  clipboard and — when "Paste on click" is on and Accessibility is granted — reactivates
  the previously frontmost app and synthesizes ⌘V so the clip lands in the focused field.
- `MenuContentView` is shared by both surfaces. The auto-convert toggle and the "Paste as"
  (Rich Text / Markdown / Plain Text) action row render **only in the overlay** (gated on
  `onPick != nil`); the menu-bar dropdown shows just search + history + footer. The "Paste
  as" buttons rewrite the clipboard then paste it via `onPasteCurrent`.
- `NSPanel.collectionBehavior`: `.canJoinAllSpaces` and `.moveToActiveSpace` are mutually
  exclusive — setting both raises an NSException (which a Carbon hotkey callback silently
  swallows, so the window just never appears). Use one.

## Hard-won design decisions — do not regress

- **Auto-paste is back, but only for the standalone history window.** Synthetic ⌘V
  (`PasteService`, CGEvent) needs the Accessibility permission (`AccessibilityPermissionManager`).
  It was removed in commit 159a62a and deliberately reintroduced afterward for the
  click-to-paste history window. The flow: capture `NSWorkspace.frontmostApplication` on
  `show()`, restore the clip, `markOwnWrite()` so the monitor won't transform it mid-paste,
  reactivate the captured app, then ⌘V after a short delay. The three clipboard-rewrite
  hotkeys (convert/restore/plain) still **never** paste — the user presses ⌘V. Accessibility
  not granted → falls back to copy-only and prompts. The frontmost-window screenshot+OCR
  feature stays reverted — don't reintroduce Screen Recording permission.
- **The menu panel uses `.menuBarExtraStyle(.window)`**, not `.menu`, because the native
  menu style cannot host the live search `TextField`. `menuBarExtraAccess` must be chained
  directly on the `MenuBarExtra` scene (it extends that concrete type, not `some Scene`).
- **Marker type before everything.** Any pasteboard write Marky makes must include the
  `com.sunnymodi.marky` marker and call `markOwnWrite()` to register the changeCount,
  otherwise the monitor loops on its own output.
- **Detection sensitivity UI was removed.** `MarkyCore.Sensitivity` (low/normal/high
  thresholds) still exists, but the app always uses `ConvertConfig()` defaults (normal,
  400-line safety valve). Don't resurface the picker without being asked.
- The ScrollView in the menu panel has no intrinsic height — it's sized from row count
  (`listHeight`); only `maxHeight` collapses to zero.

## Layout

```
Sources/
├── MarkyCore/            # pure logic, shared by app + CLI + tests
│   ├── MarkdownConverter.swift   # cmark-gfm C API -> HTML + CSS -> NSAttributedString -> RTF
│   ├── MarkdownDetector.swift    # score-based heuristics + negative gates
│   └── ConvertConfig.swift       # Sensitivity enum, maxLines safety valve
├── Marky/                # menu-bar app
│   ├── MarkyApp.swift            # MenuBarExtra (.window style), status icon pulse
│   ├── ClipboardMonitor.swift    # polling loop, marker handling, pasteboard IO
│   ├── ClipboardHistory.swift    # ClipboardHistoryStore: record/search/restore/persist
│   ├── ImageTextRecognizer.swift # Vision OCR for image clippings
│   ├── HotkeyManager.swift       # KeyboardShortcuts names + handlers (clipboard-only)
│   ├── HistoryPanelController.swift # standalone floating history window + paste flow
│   ├── PasteService.swift        # CGEvent ⌘V (Accessibility-gated)
│   ├── AccessibilityPermissionManager.swift # AXIsProcessTrusted state + prompt
│   ├── MenuContentView.swift     # search bar, history list, convert actions, footer; onPick hook
│   ├── SettingsView.swift        # General / History / Shortcuts / About panes
│   └── AppSettings.swift         # UserDefaults-backed @Published settings
└── MarkyCLI/main.swift   # pbpaste | marky -, --html, --detect
```

## Conversion pipeline (MarkyCore)

Markdown → cmark-gfm HTML fragment (extensions: table, strikethrough, autolink, tasklist)
→ wrapped in a minimal CSS document → `NSAttributedString(html:)` → RTF data.

- `NSAttributedString(html:)` must run on the **main thread**; `convert(_:)` is
  `@MainActor` for that reason.
- cmark C API notes: register extensions via
  `cmark_gfm_core_extensions_ensure_registered()`, feed UTF-8 bytes with
  `cmark_parser_feed`, render with `cmark_render_html` + parser's syntax extensions,
  `free()` the returned C string. Options stay `0` (CMARK_OPT_* macros don't import
  into Swift).

## Detector heuristics (MarkdownDetector)

Score-based: strong cues 2 points (headings, bold, links, fenced code pairs), tables 3
points (unambiguous), moderate cues 1 point (lists 2+, blockquotes, inline code, italic,
strikethrough, task lists). Negative gates return 0 outright: bare URLs, shell commands
(known command prefixes + flags/pipes heuristics), source code (braces + keywords, unless
markdown cues score ≥ 4), > 400 lines. Normal threshold is 3.

## Hotkeys (KeyboardShortcuts package)

| Name (UserDefaults key) | Default | Action |
|---|---|---|
| `.openHistory` ("openHistory") | ⌥⌘V | toggle the standalone floating history window; pick a clip to paste it |
| `.convertToRichText` ("pasteRichText") | ⌥⌘M | force-convert clipboard to rich text |
| `.restoreOriginal` ("pasteOriginal") | ⌥⇧⌘M | rewrite clipboard as original markdown, plain only |
| `.copyPlainText` ("copyPlainText") | ⌥⌘P | strip all formatting from any clipboard content |

The `KeyboardShortcuts.Name` extension is `@MainActor` (Swift 6 strict concurrency).
Old raw keys are kept for users' saved bindings — don't rename them.

## Keyboard navigation (history window + menu panel)

`MenuContentView` is shared by the menu-bar dropdown and the standalone history window
(via `onPick`). Both are fully keyboard-operable (like Windows Win+V):
- **⌥⌘V** (global) toggles the standalone window open/closed.
- **↑/↓** move selection through history items; Up from the top returns focus to
  the search field.
- **Return** picks the selected entry; **click** picks too. In the standalone window a
  pick pastes into the prior app (⌘V); in the menu dropdown it copies and closes.
- **Esc** / click-away (`windowDidResignKey`) closes the window.
- The search field is focused on open; typing filters and resets selection.
Selection highlight uses `Color.accentColor`; `ScrollViewReader` keeps the
selected row scrolled into view.

## Commands

```sh
swift build                       # debug build
swift test                        # 49 tests, 6 suites (Swift Testing, @Test/#expect)
./Scripts/package_app.sh release  # SPM binary -> Marky.app (stable-signed, copies *.bundle)
./Scripts/compile_and_run.sh      # kill, build, test, package debug, relaunch
swift run MarkyCLI --detect -     # CLI: score stdin; also --html, file args, clipboard default
```

Always relaunch via `compile_and_run.sh` or `package_app.sh` + `open Marky.app` after
changes — a stale running instance keeps the old binary's behavior.

**Code signing & the Accessibility (TCC) grant.** `package_app.sh` signs with a STABLE
identity (auto-detected Developer ID / Apple Development, override via `MARKY_SIGN_ID`),
falling back to ad-hoc only if none exists. This matters: **ad-hoc signing does NOT make
the Accessibility grant persist** — its identity is the binary hash, which changes every
build, so macOS revokes the grant as "modified since granted" and re-prompts on every
rebuild. A real signing identity gives a stable designated requirement (team + bundle id),
so the grant sticks. After changing the signing identity, run
`tccutil reset Accessibility com.sunnymodi.marky` once and re-grant.

## Testing conventions

- Swift Testing (`@Suite`/`@Test`/`#expect`), not XCTest.
- Pasteboard tests use private named pasteboards: `NSPasteboard(name: .init("marky-tests-<uuid>"))`.
- Settings tests use throwaway `UserDefaults(suiteName:)` so `.standard` is untouched.
- Never call anything that synthesizes events or captures the screen from tests.
- OCR tests render text into an `NSImage` and verify Vision reads it back.

## Dependencies (keep minimal)

- `swift-cmark` (branch `gfm`) — products `cmark-gfm`, `cmark-gfm-extensions`
- `KeyboardShortcuts` (1.x) — global hotkeys + recorder UI
- `MenuBarExtraAccess` — NSStatusItem access for the icon pulse

Sparkle/notarization intentionally out of scope so far; distribution is local
`package_app.sh` + Login Items.
