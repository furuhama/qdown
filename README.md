# Qdown

A document-based macOS Markdown viewer written in Swift and AppKit that renders content in WKWebView.

## Features

- **Fixed Quiet Light theme.** Qdown applies `Qdown/Resources/quiet-light.css` as
  its only theme. There is no theme switching and no color re-derivation.
- **Heading sidebar.** Every heading from h1 through h6 is listed in the left
  sidebar; clicking one scrolls the document to that heading.
- **Find in page.** Search with ⌘F, move between matches with ⌘G and ⇧⌘G, and
  close the find bar with Esc.
- **Persistent zoom.** Zoom the document with ⌘+ and ⌘−, or reset to actual size
  with ⌘0. The zoom level is stored in `UserDefaults`.
- **Native window tabs.** Open several Markdown files as tabs in one window
  using macOS's standard `NSWindow` tabbing. Each tab keeps its own document,
  heading sidebar, find state, zoom, and scroll position.
- **Relative links open in a new tab.** A relative Markdown link opens as a new
  tab in the same window; http(s) links open in the default browser.
- **Bundled dependencies.** marked, highlight.js, and Mermaid are vendored into
  the app, so rendering requires no network access.
- **Themed Mermaid diagrams.** Mermaid diagrams are rendered with the Quiet
  Light palette.

## Requirements

- macOS 13.0 or later
- Xcode, to build from source
- Universal binary (arm64 + x86_64)

## Build

```sh
./scripts/build.sh
```

The build output is:

```
build/Release/Qdown.app
```

To invoke `xcodebuild` directly:

```sh
xcodebuild -project Qdown.xcodeproj -scheme Qdown -configuration Release \
  -derivedDataPath "$PWD/build/DerivedData" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
```

## Usage

Open `.md`, `.markdown`, or `.txt` files by double-clicking them in Finder,
using Open With, dragging them onto Qdown, or choosing File > Open…. If a Qdown
window is already open, the file joins that window as a new tab. Use File >
New Tab… (⌘T) to pick another file, and drag a tab out (or use Window > Move Tab
to New Window) to detach it.

| Action | Shortcut |
| --- | --- |
| Open a file in a new tab | ⌘T |
| Next / previous tab | ⌃Tab / ⌃⇧Tab |
| Find in page | ⌘F |
| Next match | ⌘G |
| Previous match | ⇧⌘G |
| Close the find bar | Esc |
| Zoom in / out | ⌘+ / ⌘− |
| Actual size | ⌘0 |

Click a heading in the left sidebar to scroll to it. Relative Markdown links
open in a new tab in the same window, while http(s) links open in your default
browser.

The application menu also provides **Set Qdown as Default Markdown Viewer…**,
which registers Qdown as the default application for `.md` files. Running it
changes the system's default application setting.

## Development

### Automated verification

```sh
./scripts/verify.sh
```

This expects `build/Release/Qdown.app` to have been built already. The script
runs the following checks:

- Rendering through the real WKWebView, scheme handler, `viewer.html`, CSS, and
  JavaScript
- DOM checks for headings, tables, task lists, code blocks, blockquotes, images,
  and Mermaid
- Quiet Light computed colors (background `#F0F0F7`, headings `#705697`, and
  Mermaid `#EDEDF5` / `#705697` / `#333333`)
- Search using both the CSS Custom Highlight API and the `<mark>` fallback
- Horizontal scrolling and Mermaid overflow at narrow widths (520px and 380px)
  and at a wide width (1400px)
- Native window smoke tests: multiple windows, sidebar, match count, zoom
  persistence, sidebar clicks, and relative Markdown links opening as tabs in
  the same window
- Native tab checks: two documents open into one window with two tabs whose
  titles are the file names, per-tab sidebar state, and scroll position
  preserved across tab switches
- Standard tab detach/merge via `NSWindow` actions, plus the Window menu tab
  commands
- Real LaunchServices (`open -a`, Finder-style) open events produce one window
  with two tabs
- Blocking of external images, iframes, `javascript:` links, and raw `<script>`
- `lipo -info` confirmation of the arm64 + x86_64 slices

Results are written to `build/test-output/` as JSON and PNG snapshots.

### Verification harness

The app binary is always launched **without arguments**, and test settings are
passed through `QDOWNTEST_*` environment variables. macOS's
`NSDocumentController` treats file-like argv entries as documents to open, so
passing arguments in an unattended run can leave the app waiting on a modal
dialog. `scripts/verify.sh` wraps every launch in `timeout` and cleans up with
`pkill -x Qdown` before and after each run.

```sh
# Rendering test (real WKWebView / real scheme handler)
QDOWNTEST_MODE=render \
QDOWNTEST_MARKDOWN=test.md \
QDOWNTEST_JSON=build/test-output/render.json \
QDOWNTEST_SNAPSHOT=build/test-output/top.png \
QDOWNTEST_SNAPSHOT_DIAGRAM=build/test-output/mermaid.png \
QDOWNTEST_SNAPSHOT_SECTION=build/test-output/section.png \
QDOWNTEST_FIND=Mermaid \
  build/Release/Qdown.app/Contents/MacOS/Qdown

# Native window smoke test
QDOWNTEST_MODE=smoke \
QDOWNTEST_FILES=$'test.md\nTests/fixtures/other.md' \
  build/Release/Qdown.app/Contents/MacOS/Qdown

# Tab test (two documents, one window, two tabs)
QDOWNTEST_MODE=tabs \
QDOWNTEST_FILES=$'test.md\nTests/fixtures/other.md' \
QDOWNTEST_JSON=build/test-output/tabs.json \
  build/Release/Qdown.app/Contents/MacOS/Qdown

# Real LaunchServices open events (start the app, then `open -a` two files)
QDOWNTEST_MODE=live-tabs \
QDOWNTEST_EXPECT_COUNT=2 \
QDOWNTEST_JSON=build/test-output/live-tabs.json \
  build/Release/Qdown.app/Contents/MacOS/Qdown
```

Common environment variables:

| Variable | Purpose |
| --- | --- |
| `QDOWNTEST_MODE` | `render`, `smoke`, `tabs`, or `live-tabs` |
| `QDOWNTEST_MARKDOWN` | Markdown file to render |
| `QDOWNTEST_JSON` | Output path for the result JSON |
| `QDOWNTEST_SNAPSHOT` / `_DIAGRAM` / `_SECTION` | PNG snapshot output paths |
| `QDOWNTEST_FIND` / `QDOWNTEST_FALLBACK` | Search term / `<mark>` fallback |
| `QDOWNTEST_FILES` | Files to open in the smoke and tab tests (newline-separated) |
| `QDOWNTEST_SIDEBAR_SNAPSHOT` | Output path for the sidebar PNG |
| `QDOWNTEST_ZOOM_READ_ONLY` | `1` reads the UserDefaults zoom value without modifying it |
| `QDOWNTEST_LINK` | `1` verifies that a relative link opens a new tab in the same window |
| `QDOWNTEST_EXPECT_COUNT` | Documents expected from LaunchServices open events (`live-tabs`) |

The legacy `--render-test` / `--smoke-test` forms are also accepted for backward
compatibility, but should not be used in unattended runs.

## Project structure

```
Qdown/
  Info.plist                 # Document types, UTIs, app metadata
  Sources/
    main.swift               # NSApplication startup (no storyboard)
    AppDelegate.swift        # Menus, file opening, default-app registration
    Document.swift           # NSDocument, text encoding detection
    DocumentOpenCoordinator.swift # Same-window tab opening policy for all entry points
    DocumentWindowController.swift
    MarkdownWebView.swift    # WKWebView, JS bridge, drag and drop
    LocalSchemeHandler.swift # qdown://app and qdown://doc, network blocking
    SidebarViewController.swift
    FindBarView.swift        # Find bar and content view
    LinkRouter.swift
    ZoomStore.swift
    RenderTestRunner.swift   # QDOWNTEST_MODE=render / smoke / tabs / live-tabs
  Resources/
    quiet-light.css          # Canonical theme; not modified
    viewer.html / viewer.css / viewer.js
    vendor/                  # marked, highlight.js, mermaid (no network at runtime)
Tests/
  fixtures/                  # Relative links, images, security checks
test.md                      # Sample headings, tables, tasks, code, quotes, Mermaid
```

## Theme

`Qdown/Resources/quiet-light.css` is the canonical theme and is loaded as-is;
the viewer does not re-derive its colors. `viewer.css` adds only behavior the
theme does not cover, such as search highlighting, Mermaid scaling, and
preventing images from overflowing the page.

## Vendored libraries

Dependencies are fetched with `scripts/vendor.sh` (network access is used only
at build time).

| Library | Version | License |
| --- | --- | --- |
| marked | 12.0.2 | MIT |
| highlight.js (@highlightjs/cdn-assets) | 11.11.1 | BSD-3-Clause |
| mermaid | 10.9.5 | MIT |

Full license texts are included under `Qdown/Resources/vendor/`.

## Runtime network access

- Pages load only through two custom schemes: `qdown://app` for application
  assets and `qdown://doc` for images inside the document's directory.
- The Content Security Policy sets `default-src 'none'`, `connect-src 'none'`,
  and `img-src qdown: data:`, rejecting http(s) scripts, styles, images, and
  frames.
- A `WKContentRuleList` additionally blocks http(s), ws(s), and ftp.
- The app uses `WKWebsiteDataStore.nonPersistent()`.
- External images in Markdown are blocked by the CSP, their `src` is removed
  from the DOM, and a placeholder is shown instead.

## Limitations

- Qdown is a viewer. It does not reload files when they change on disk, edit
  documents, print or export PDFs, or preview documents in Quick Look.
- A relative Markdown link that points to a document already open may reuse the
  existing window, depending on `NSDocumentController` behavior.
