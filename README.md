# Qdown

A document-based macOS Markdown viewer written in Swift and AppKit that renders content in WKWebView.

## Features

- **Fixed Quiet Light theme.** Qdown applies `Qdown/Resources/quiet-light.css` as
  its only theme. There is no theme switching and no color re-derivation.
- **Floating outline.** Every heading from h1 through h6 appears as a short
  bar along the right edge of the window, 12pt in from the edge, and the bar
  for the section you are reading is highlighted. In narrow windows the margin
  tightens just enough to keep the bars clear of the text column. Hover the
  bars to open a hierarchical list; clicking a bar or an entry smooth-scrolls
  to that heading. The invisible hover target is the 44pt strip at the window's
  right edge, the expanded panel overlaps it so there is no dead zone, and a
  400ms grace period lets the pointer travel diagonally into the panel without
  closing it. The outline is a page overlay: it never reflows the document, is
  not part of ⌘F results, is excluded from ⌘A, and keeps a constant on-screen
  size at every zoom level. The 12pt window margin is also constant at every
  zoom level when the text column leaves room for it; narrow windows tighten
  the margin only as needed to keep the bars clear of the text.
- **Find in page.** Search with ⌘F, move between matches with ⌘G and ⇧⌘G, and
  close the find bar with Esc.
- **Persistent zoom.** Zoom the document with ⌘+ and ⌘−, or reset to actual size
  with ⌘0. The zoom level is stored in `UserDefaults`.
- **Tab session restore.** The open tabs (paths, order, and the active tab) are
  saved whenever a tab is opened, closed, reordered, or selected, and again when
  Qdown quits. The next launch reopens them in order. Tabs whose files no longer
  exist are skipped, duplicate tabs are preserved, an empty session starts
  empty, and opening files from Finder or the command line takes precedence
  over the old session.
- **Live reload.** Qdown watches the open document's path and its parent
  directory. When another editor writes the file, the page reloads after a
  short debounce. Atomic saves (write a sibling, then `rename` over the
  document) are detected because the path is re-resolved after every event,
  not just the original file descriptor. Scroll position and zoom survive the
  reload, unchanged contents (an mtime-only touch) do not re-render, deleting
  the file keeps the last display, and recreating the same path reloads it.
  Background tabs update without taking focus.
- **Native window tabs.** Open several Markdown files as tabs in one window
  using AppKit's standard `NSWindow` tab bar. Detach, merge, ⌃Tab, Close Tab,
  the Window menu, and LaunchServices opens all use the system behaviour, and
  the tab bar is the only element that splits the window. Each tab keeps its
  own document, outline, find state, zoom, and scroll position.
- **Headerless window.** The titlebar is transparent (`fullSizeContentView` +
  `titlebarAppearsTransparent`) and the title is hidden. When tabs are shown
  AppKit's native tab bar occupies the titlebar row and the page starts below
  its safe area. With a single document the tab bar is hidden automatically
  (the filename stays set as the window/tab title, as before), and only the
  28-point traffic-light strip remains above the page; that strip is a
  draggable window region and the page background reaches the window's top
  edge. The handle moves the window itself from the screen-space cursor delta
  captured at mouse-down instead of handing the drag to `NSWindow.performDrag`;
  its hit test runs in the content view's coordinate space. Recomputing the
  origin from the absolute cursor delta keeps the grab point fixed even when
  the window server pauses frame delivery for a display transition with a
  different backing scale.
- **Relative links open in a new tab.** A relative Markdown link opens as a new
  tab in the same window; http(s) links open in the default browser.
- **Bundled dependencies.** marked, highlight.js, and Mermaid are vendored into
  the app, so rendering requires no network access.
- **Application icon.** A light Quiet Light tile with a purple Q whose tail is a
  downward arrow, generated procedurally at every required size and embedded in
  the app bundle as `AppIcon.icns`.
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

The build regenerates `Qdown/Resources/AppIcon.icns` with
`scripts/generate_icon.swift` (CoreGraphics) before invoking `xcodebuild`.
To regenerate the icon and its preview by hand:

```sh
swift scripts/generate_icon.swift \
  --output Qdown/Resources/AppIcon.icns \
  --preview /tmp/qdown-icon.png
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

Move the pointer to the right edge of the window to open the outline, then
click a bar or an entry to scroll to that heading. Relative Markdown links open
in a new tab in the same window, while http(s) links open in your default
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
- Floating outline: one bar per heading, the level classes, the active bar
  following both a programmatic jump and a bar click, the hover/test panel
  expanding without reflow, `#qdown-outline` staying outside `#content`, and ⌘F
  never matching outline text
- Outline hover intent: the invisible hit strip is ~44pt wide at the window's
  right edge (constant at every page zoom) and contains the bars, the panel
  overlaps the strip, leaving the merged region keeps the panel open for the
  400ms grace period, and re-entry cancels the pending close
- Outline zoom invariance at page zoom 0.5 / 1.0 / 1.25 / 2.5: the effective
  bar width and the 12pt window-right margin stay constant, the bars stay clear
  of the text column, and the page never overflows horizontally
- Narrow-window outline: the 6–8pt bar variant at 520px/380px, with the window
  margin clamped only as far as needed to keep the bars off the text
- Native window smoke tests: multiple windows, outline heading counts, match
  count, zoom persistence, outline clicks, and relative Markdown links opening
  as tabs in the same window
- Live reload: an in-place write and an atomic sibling-file `rename` both
  replace the DOM text, scroll position and zoom are preserved across the
  re-render, an mtime-only touch does not re-render, deleting the file keeps
  the last display, and recreating the path reloads it without changing the
  key window
- Window-tab checks: two documents open into one window with two tabs whose
  titles are the file names, per-tab outline state, and scroll position
  preserved across tab switches
- Standard tab detach/merge via `NSWindow` actions, plus the Window menu tab
  commands
- Real LaunchServices (`open -a`, Finder-style) open events produce one window
  with two tabs
- Headerless chrome: `fullSizeContentView`, transparent titlebar, hidden title,
  no titlebar separator, content below the traffic lights, and the top strip
  exposed as a draggable region. The drag-region checks resolve the handle
  through the real content-view hit-test path (not the view's own bounds), at
  the top edge, with the height matching the current safe area, and confirm the
  screen-delta drag handoff (`screenDelta`) rather than `NSWindow.performDrag`.
- Native tab bar: AppKit's tab bar is visible when a window has 2+ tabs, the
  safe area grows beyond the 28pt single-window strip, the WebView starts below
  it, and the bar spans the whole window
- Closing tabs back to one document restores the headerless layout with the
  original 28-point safe area and no tab bar
- Real-screen geometry: the app writes its window number and holds while
  `screencapture` records the window. The tabbed capture, the expanded-outline
  capture, and the single-document capture are each checked against their
  metadata (native tab bar / safe area / content top / headerless top edge)
- Blocking of external images, iframes, `javascript:` links, and raw `<script>`
- `lipo -info` confirmation of the arm64 + x86_64 slices

Results are written to `build/test-output/` as JSON and PNG snapshots. The
headerless-chrome screenshots are `05-headerless-window.png` /
`06-headerless-content.png` (no tabs) and `07-headerless-tabs-window.png` /
`08-headerless-tabs-content.png` (window with tabs). Real `screencapture`
images are `09-real-tabs-window.png` (native tab bar + outline bars),
`10-outline-panel.png` (outline panel expanded), and `11-single-window.png`
(single document, headerless). `Tests/verify_tab_geometry.py` runs on each of
the three real-screen images and checks the native-tab-bar/full-width geometry
and the page top / 28pt single-window strip. The harness JSON from those
captures also reports the measured outline right-edge gap and verifies that the
bars sit 12pt from the window edge and stay clear of the text.

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

# Single-document real-screen capture (writes windowNumber, then holds)
QDOWNTEST_MODE=window \
QDOWNTEST_FILES=test.md \
QDOWNTEST_OUTLINE_EXPANDED=1 \
QDOWNTEST_SCREEN_JSON=build/test-output/outline-screen.json \
QDOWNTEST_HOLD_SECONDS=20 \
  build/Release/Qdown.app/Contents/MacOS/Qdown
```

Common environment variables:

| Variable | Purpose |
| --- | --- |
| `QDOWNTEST_MODE` | `render`, `smoke`, `tabs`, `live-tabs`, `live-reload`, or `window` |
| `QDOWNTEST_MARKDOWN` | Markdown file to render |
| `QDOWNTEST_JSON` | Output path for the result JSON |
| `QDOWNTEST_SNAPSHOT` / `_DIAGRAM` / `_SECTION` | PNG snapshot output paths |
| `QDOWNTEST_FIND` / `QDOWNTEST_FALLBACK` | Search term / `<mark>` fallback |
| `QDOWNTEST_FILES` | Files to open in the smoke and tab tests (newline-separated) |
| `QDOWNTEST_WINDOW_SNAPSHOT` | Output path for a whole-window PNG (theme frame, traffic lights included) |
| `QDOWNTEST_CONTENT_SNAPSHOT` | Output path for a content-view PNG (page, no titlebar) |
| `QDOWNTEST_ZOOM_READ_ONLY` | `1` reads the UserDefaults zoom value without modifying it |
| `QDOWNTEST_LINK` | `1` verifies that a relative link opens a new tab in the same window |
| `QDOWNTEST_EXPECT_COUNT` | Documents expected from LaunchServices open events (`live-tabs`) |
| `QDOWNTEST_LIVE_FILE` | Fixture path rewritten by the `live-reload` harness |
| `QDOWNTEST_SCREEN_ONLY` | `1` stops the tabs harness after the initial 2+ tab window is stable (real-screen capture) |
| `QDOWNTEST_SCREEN_JSON` | JSON output path for the screen-only mode (includes `windowNumber`) |
| `QDOWNTEST_HOLD_SECONDS` | Keeps the screen harness alive for an external `screencapture` |
| `QDOWNTEST_OUTLINE_EXPANDED` | `1` opens the outline panel in `window` mode (screenshot hook) |
| `QDOWNTEST_ZOOM` | Page zoom to apply in `window` mode |

The legacy `--render-test` / `--smoke-test` forms are also accepted for backward
compatibility, but should not be used in unattended runs.

## Project structure

```
Qdown/
  Info.plist                 # Document types, UTIs, app metadata
  Sources/
    main.swift               # NSApplication startup (no storyboard)
    AppDelegate.swift        # Menus, file opening, default-app registration
    Document.swift           # NSDocument, text encoding detection, live reload hook
    DocumentFileWatcher.swift # Path-based kqueue watcher (directory + file)
    DocumentOpenCoordinator.swift # Same-window tab opening policy for all entry points
    DocumentWindowController.swift
    MarkdownWebView.swift    # WKWebView, JS bridge, drag and drop
    LocalSchemeHandler.swift # qdown://app and qdown://doc, network blocking
    FindBarView.swift        # Find bar and content view (page reaches the top edge)
    LinkRouter.swift
    ZoomStore.swift
    RenderTestRunner.swift   # QDOWNTEST_MODE=render / smoke / tabs / live-tabs / live-reload / window
  Resources/
    quiet-light.css          # Canonical theme; not modified
    viewer.html / viewer.css / viewer.js  # Markdown page + floating outline
    vendor/                  # marked, highlight.js, mermaid (no network at runtime)
Tests/
  verify_results.py          # JSON/PNG assertions for the harness output
  verify_tab_geometry.py     # Real-screen native-tab/outline geometry checks
  fixtures/                  # Relative links, images, security checks
test.md                      # Sample headings, tables, tasks, code, quotes, Mermaid
```

## Theme

`Qdown/Resources/quiet-light.css` is the canonical theme and is loaded as-is;
the viewer does not re-derive its colors. `viewer.css` adds only behavior the
theme does not cover, such as search highlighting, Mermaid scaling, preventing
images from overflowing the page, and the floating outline overlay.

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

- Qdown is a viewer. It does not edit documents, print or export PDFs, or
  preview documents in Quick Look.
- A relative Markdown link that points to a document already open may reuse the
  existing window, depending on `NSDocumentController` behavior.
