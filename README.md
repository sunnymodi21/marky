<p align="center">
  <img src="Assets/AppIconSource.png" width="128" alt="Marky app icon">
</p>

<h1 align="center">Marky</h1>

<p align="center">
  A private, keyboard-first clipboard companion for macOS.<br>
  Paste Markdown as rich text, search clipboard history, OCR images, and fill forms from copied text.
</p>

<p align="center">
  <a href="https://marky.click">Website</a> ·
  <a href="https://download.marky.click/Marky.dmg">Download</a> ·
  <a href="https://github.com/sunnymodi21/marky">GitHub</a> ·
  <a href="https://marky.click/privacy">Privacy</a>
</p>

Marky is a native Swift menu-bar app for macOS 15 and later. It watches the
clipboard, recognizes Markdown, and adds rich-text representations without
changing the original plain text. It also keeps a local clipboard history,
performs on-device OCR, and can match copied contact details to form fields
with a local GLiNER model.

Everything is designed to stay on the Mac. Clipboard contents are never sent
to a server.

## Features

- **Markdown → rich text:** copy Markdown and paste formatted headings, links,
  lists, tables, task lists, code, and emphasis into rich-text apps.
- **Non-destructive clipboard writes:** the same pasteboard item contains RTF,
  HTML, and the original Markdown as plain text.
- **Clipboard history:** search and restore copied text and images from a
  keyboard-driven floating panel.
- **Paste on pick:** select a history item and return it directly to the app
  you were using.
- **On-device OCR:** extract text from copied images with Apple Vision.
- **Smart Fill:** copy unstructured contact information, focus a form, and let
  a local GLiNER2.5 model fill confident matches.
- **Privacy filters:** concealed and transient password-manager items are never
  converted or recorded.
- **App exclusions and regex filters:** skip clipboard content from selected
  apps or content matching custom patterns.
- **CLI:** use the same Markdown detector and converter from scripts.

## How clipboard conversion works

Suppose you copy:

```markdown
# Status update

**Done:** shipped the *parser*.

- Fixed [the bug](https://example.com)
- Added tests
```

Marky rewrites the clipboard as one `NSPasteboardItem` with several
representations:

| Representation | Used by | Contents |
|---|---|---|
| `public.rtf` | Mail, Notes, Pages, Word | Rendered rich text |
| `public.html` | Google Docs, Slack, browsers | Styled HTML |
| `public.utf8-plain-text` | Editors and terminals | Original Markdown, unchanged |
| `com.sunnymodi.marky` | Marky | Marker that prevents processing loops |

Plain-text apps therefore continue to receive exactly what you copied.

## Default shortcuts

All shortcuts can be changed or cleared in Marky → Settings → Shortcuts.

| Shortcut | Action |
|---|---|
| <kbd>⌥⌘V</kbd> | Open clipboard history |
| <kbd>⌥⌘F</kbd> | Smart Fill the focused form from clipboard text |
| <kbd>⌥⌘M</kbd> | Force-convert the clipboard to rich text |
| <kbd>⌥⇧⌘M</kbd> | Restore the original Markdown |
| <kbd>⌥⌘P</kbd> | Copy as plain text |

The three conversion shortcuts rewrite the clipboard but do not synthesize a
paste. Press <kbd>⌘V</kbd> when you are ready.

## Requirements

For normal development:

- macOS 15 or later
- Xcode 16 or later, or a Swift 6 command-line toolchain
- Git

No package manager, database, JavaScript runtime, or Python installation is
required to build the app or run its tests. SwiftPM resolves all Swift and C
dependencies.

Python is only relevant in these cases:

- A **debug build** creates a local virtual environment when Smart Fill is
  invoked for the first time. It accepts Python 3.10–3.13.
- A **direct release build** embeds a relocatable Python runtime automatically.
  The current runtime packaging script targets Apple silicon (`arm64`).
- The downloadable release already contains Python; users do not install it.

## Quick start

Clone the repository and run the development loop:

```sh
git clone https://github.com/sunnymodi21/marky.git
cd marky
swift package resolve
./Scripts/compile_and_run.sh
```

`compile_and_run.sh` stops any existing Marky process, builds the app, runs the
test suite, packages `Marky.app`, and relaunches it.

For a faster logic-only check:

```sh
swift test
```

For a build without launching the app:

```sh
swift build
./Scripts/package_app.sh debug
```

The packaged app appears at `./Marky.app`.

### Trying Smart Fill in a debug build

Install a supported Python version if one is not already available:

```sh
brew install python@3.12
```

Then:

1. Launch the packaged debug app.
2. Grant Accessibility permission when prompted.
3. Copy text containing details such as a name, phone number, or email.
4. Focus a form and press <kbd>⌥⌘F</kbd>.

On first use, Marky creates a virtual environment and downloads the model. The
model is approximately 783 MB and is stored under:

```text
~/Library/Application Support/Marky/gliner/
```

Subsequent inference is local and runs offline.

## Common development commands

| Command | Purpose |
|---|---|
| `swift build` | Build the debug targets |
| `swift build -c release` | Build optimized targets |
| `swift test` | Run all tests |
| `swift test --filter MarkdownDetectorTests` | Run a focused suite |
| `./Scripts/compile_and_run.sh` | Build, test, package, and relaunch |
| `./Scripts/package_app.sh debug` | Create a lightweight development app |
| `./Scripts/package_app.sh release` | Create a release app with bundled Python |
| `./Scripts/prepare_python_runtime.sh` | Prepare the pinned, pruned Smart Fill runtime |

The first release-runtime build downloads Python and pinned ML dependencies.
The prepared runtime is cached in `.build/marky-python-runtime`.

## CLI

The `MarkyCLI` target exposes Markdown detection and conversion for scripts:

```sh
# Convert the current clipboard in place
swift run MarkyCLI

# Read Markdown from stdin and write rich text to the clipboard
pbpaste | swift run MarkyCLI -

# Print generated HTML
swift run MarkyCLI --html README.md

# Inspect the Markdown detection score
printf '# Hello\n\n- one\n- two\n' | swift run MarkyCLI --detect -
```

Exit codes are `0` for success, `1` for missing input or another input error,
and `2` when detection or conversion does not succeed.

## Project structure

```text
Sources/
├── MarkyCore/                Markdown detection and conversion
├── Marky/                    Menu-bar app and macOS services
│   └── SmartFill/            AX form scanning and local GLiNER worker
└── MarkyCLI/                 Command-line interface
Tests/MarkyTests/             Swift Testing suites
Scripts/                      Build, packaging, notarization, and release tools
Signing/                      App Store entitlements
website/                      Static marky.click site
```

The main runtime flows are intentionally separated:

```text
Clipboard change
  → ClipboardMonitor
  → ClipboardPolicy
  → MarkdownDetector
  → MarkdownConverter
  → PasteboardService

Smart Fill shortcut
  → AccessibilityFormScanner
  → GLiNERService / gliner_worker.py
  → FieldContextBuilder
  → AccessibilityFormWriter
```

### Important implementation details

- macOS has no clipboard-change notification API, so Marky polls
  `NSPasteboard.general.changeCount` approximately every 150 ms.
- Promised pasteboard data gets a short grace period before it is read.
- Markdown is rendered through cmark-gfm, HTML, `NSAttributedString`, and RTF.
- `NSAttributedString(html:)` must run on the main actor.
- Every Marky pasteboard write goes through `PasteboardService`, includes the
  marker type, and registers its new `changeCount`.
- Clipboard history stores image metadata in JSON and PNG bytes in separate
  files so images can be loaded lazily.
- Smart Fill builds its extraction schema from the form fields that macOS
  Accessibility exposes. It fills only empty, non-sensitive fields above the
  confidence threshold.

## Tests

The project uses Swift Testing (`@Suite`, `@Test`, and `#expect`):

```sh
swift test
```

With the local Smart Fill model installed, the browser examples can also be
run as an end-to-end extraction suite:

```sh
~/Library/Application\ Support/Marky/gliner/venv/bin/python \
  Scripts/test_smart_fill_examples.py
```

Pass one or more HTML filenames to run a smaller subset. The generated fixtures
can be rebuilt after catalog changes with:

```sh
python3 Scripts/generate_smart_fill_examples.py
```

The 30 semantic HTML fixtures include 11 multi-step flows, mixed controls, and
adversarial DOM cases covering opaque attributes, accessible naming variants,
placeholder fallbacks, repeated groups, and dynamically revealed steps.

The suite covers Markdown detection and conversion, pasteboard behavior,
history persistence, privacy filters, OCR, and Smart Fill schema/response
handling. Tests use private named pasteboards and temporary `UserDefaults`
suites; they do not synthesize keyboard events or modify the system clipboard.

When changing clipboard behavior, add a regression test for the marker and
`changeCount` protocol. When changing Smart Fill, keep model-independent logic
covered in Swift tests and test the Python worker separately against a local
model snapshot.

## Permissions and privacy

Marky works without Accessibility permission for clipboard conversion,
history, search, and OCR.

Accessibility is used for:

- pasting a selected history item into the previously focused app;
- discovering empty fields for Smart Fill; and
- writing matched values into those fields.

Marky does **not** request Screen Recording, Contacts, Location, Photos,
Camera, or Microphone access.

The direct build makes network requests only for Sparkle update checks and the
first Smart Fill model download. Clipboard text and extracted values are not
uploaded. See the [privacy policy](https://marky.click/privacy) for the user-facing
policy.

## Troubleshooting

### The app launches, but my changes are missing

A previously running menu-bar process is probably still active. Use the full
development loop:

```sh
./Scripts/compile_and_run.sh
```

### Accessibility is requested after every local rebuild

Ad-hoc signatures are tied to the binary hash, so macOS treats each rebuild as
a different app. Install an Apple Development certificate or set a stable
signing identity:

```sh
MARKY_SIGN_ID="Apple Development: Your Name (TEAMID)" \
  ./Scripts/package_app.sh debug
```

After changing signing identities, reset the old grant once and grant it again:

```sh
tccutil reset Accessibility com.sunnymodi.marky
```

### Smart Fill cannot find Python in a debug build

Install Python 3.10–3.13 and make sure `python3` is available on `PATH`. Release
apps produced by `package_app.sh release` embed Python and do not have this
requirement.

### SwiftPM dependency state looks stale

```sh
swift package reset
swift package resolve
swift test
```

## Release packaging

Contributors generally only need the debug workflow. The following commands
are for maintainers with Apple signing and notarization credentials.

Create a direct-download release app with the bundled Smart Fill runtime. The
script uses a Developer ID or Apple Development identity when available and
falls back to ad-hoc signing for local builds:

```sh
./Scripts/package_app.sh release
```

Create a notarized DMG after incrementing `CFBundleVersion` in `Info.plist`:

Create a gitignored `.env` with the maintainer credentials:

```dotenv
APPLE_ID=developer@example.com
APPLE_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
APPLE_TEAM_ID=TEAMID
```

Then package and generate the update feed:

```sh
./Scripts/create_dmg.sh
./Scripts/generate_appcast.sh
```

`.env`, signing keys, certificates, provisioning profiles, and build artifacts
are ignored by Git. Never commit release credentials.

Mac App Store packaging is available to maintainers with the appropriate
certificate and provisioning profile:

```sh
./Scripts/package_app.sh mas
```

## Contributing

Issues and pull requests are welcome.

1. Create a focused branch.
2. Add or update tests for behavior changes.
3. Run `swift test`.
4. Run `./Scripts/compile_and_run.sh` for UI or pasteboard changes.
5. Describe the user-visible effect and manual verification in the pull
   request.

Please preserve these safety properties:

- never record pasteboard items marked concealed or transient;
- never write directly to the general pasteboard outside `PasteboardService`;
- never synthesize paste events from the conversion-only shortcuts;
- never add Screen Recording as an implicit requirement; and
- keep clipboard text and Smart Fill values on-device.

## License

[MIT](LICENSE).
