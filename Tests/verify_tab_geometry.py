#!/usr/bin/env python3
"""Verify the native tab bar geometry on a real screen capture.

The native NSWindow tab bar is drawn by the window server, so it is absent
from the app's in-process `cacheDisplay` snapshots. This script checks the
real `screencapture -l` image produced by scripts/verify.sh:

  * the tab bar row is at the top of the window,
  * the selected tab starts at the window's left edge (the regression was a
    tab strip inset by the sidebar width), and
  * the sidebar/WebView start below the tab bar.

Only the standard library is required. Pillow is used when available; when it
is not, the PNG is converted to BMP with the macOS `sips` tool and decoded
manually.
"""
import json
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

FAILURES = []
CHECKS = 0


def check(condition, label, detail=""):
    global CHECKS
    CHECKS += 1
    ok = bool(condition)
    suffix = f" ({detail})" if detail else ""
    print(("PASS " if ok else "FAIL ") + label + suffix)
    if not ok:
        FAILURES.append(label + suffix)


class Image:
    def __init__(self, width, height, pixel):
        self.width = width
        self.height = height
        self._pixel = pixel

    def pixel(self, x, y):
        return self._pixel(int(x), int(y))


def load_with_pillow(path):
    from PIL import Image as PILImage  # type: ignore
    image = PILImage.open(path).convert("RGB")
    return Image(image.width, image.height, lambda x, y: image.getpixel((x, y)))


def load_with_sips(path):
    with tempfile.TemporaryDirectory() as tmp:
        bmp = Path(tmp) / "capture.bmp"
        subprocess.run(["/usr/bin/sips", "-s", "format", "bmp",
                        str(path), "--out", str(bmp)],
                       check=True, capture_output=True)
        data = bmp.read_bytes()

    if data[:2] != b"BM":
        raise ValueError("sips did not produce a BMP file")
    offset = struct.unpack_from("<I", data, 10)[0]
    header_size = struct.unpack_from("<I", data, 14)[0]
    if header_size < 40:
        raise ValueError("unsupported BMP header")
    width, height = struct.unpack_from("<ii", data, 18)
    planes, depth = struct.unpack_from("<HH", data, 26)
    compression = struct.unpack_from("<I", data, 30)[0]
    if planes != 1 or compression != 0 or depth not in (24, 32):
        raise ValueError(f"unsupported BMP: depth={depth} compression={compression}")
    top_down = height < 0
    height = abs(height)
    row_bytes = ((width * depth + 31) // 32) * 4
    bytes_per_pixel = depth // 8

    def pixel(x, y):
        row = y if top_down else height - 1 - y
        index = offset + row * row_bytes + x * bytes_per_pixel
        blue, green, red = data[index:index + 3]
        return (red, green, blue)

    return Image(width, height, pixel)


def load_image(path):
    try:
        return load_with_pillow(path)
    except Exception:
        return load_with_sips(path)


def parse_frame(text):
    match = re.match(r"\{\{(-?[\d.]+), (-?[\d.]+)\}, \{(-?[\d.]+), (-?[\d.]+)\}\}", text or "")
    if not match:
        return None
    return tuple(float(value) for value in match.groups())


def is_neutral(pixel):
    red, green, blue = pixel
    return max(pixel) - min(pixel) <= 3 and 234 <= red <= 250


def is_tab_like(pixel):
    """Light, slightly blue page/sidebar background under a translucent tab."""
    red, green, blue = pixel
    return red >= 225 and green >= 225 and blue >= 225 and (blue - red) >= 3


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_tab_geometry.py <screenshot.png> <tabs-screen.json>")

    screenshot = Path(sys.argv[1])
    metadata_path = Path(sys.argv[2])
    if not screenshot.is_file() or screenshot.stat().st_size < 1000:
        raise SystemExit(f"missing or empty screenshot: {screenshot}")
    if not metadata_path.is_file():
        raise SystemExit(f"missing metadata: {metadata_path}")

    metadata = json.loads(metadata_path.read_text())
    chrome = metadata.get("chrome") or metadata.get("opened", {}).get("chrome") or {}
    frame = parse_frame(metadata.get("windowFrame") or chrome.get("windowFrame"))
    if not frame:
        raise SystemExit("no windowFrame in metadata")
    window_x, window_y, window_width, window_height = frame
    sidebar_width = float(chrome.get("sidebarWidth", -1))
    content_top = float(chrome.get("contentSafeAreaTop", -1))
    sidebar_header_top = float(chrome.get("sidebarHeaderTop", -1))

    image = load_image(screenshot)
    scale = image.width / window_width
    check(1.5 <= scale <= 3.0, "realTabs.captureScale", f"{scale:.3f}x")
    check(abs(image.height - window_height * scale) <= 3,
          "realTabs.captureSize",
          f"{image.width}x{image.height} for {window_width:g}x{window_height:g}pt")
    check(chrome.get("tabBarVisible") is True, "realTabs.tabBarVisible",
          str(chrome.get("tabBarVisible")))
    check(sidebar_width >= 180, "realTabs.sidebarWidth", f"{sidebar_width:g}pt")

    # The tab bar is the horizontal band whose right half is the neutral gray
    # of the unselected tabs/empty tab bar. The headerless page/sidebar colors
    # are slightly blue and therefore not neutral.
    sample_fractions = (0.60, 0.70, 0.80, 0.90, 0.97)
    qualifying = []
    for y in range(2, int(image.height * 0.35)):
        neutral = sum(1 for fraction in sample_fractions
                      if is_neutral(image.pixel(image.width * fraction, y)))
        if neutral >= 4:
            qualifying.append(y)

    runs = []
    for y in qualifying:
        if runs and y == runs[-1][1] + 1:
            runs[-1][1] = y
        else:
            runs.append([y, y])
    # Text and tab separators can interrupt a few rows in the middle of the
    # band, so join runs separated by a small gap before measuring it.
    merged = []
    for run in runs:
        if merged and run[0] - merged[-1][1] <= int(8 * scale):
            merged[-1][1] = run[1]
        else:
            merged.append(run)
    runs = [run for run in merged
            if 18 * scale <= (run[1] - run[0] + 1) <= 40 * scale]
    check(bool(runs), "realTabs.tabBarBandFound",
          f"{len(runs)} candidate band(s)")
    if not runs:
        finish()
        return
    band_top, band_bottom = min(runs, key=lambda run: run[0])
    band_height_pt = (band_bottom - band_top + 1) / scale
    band_top_pt = band_top / scale
    band_bottom_pt = (band_bottom + 1) / scale

    check(18 <= band_top_pt <= 34, "realTabs.tabBarNearTop",
          f"top={band_top_pt:.1f}pt")
    check(22 <= band_height_pt <= 34, "realTabs.tabBarHeight",
          f"{band_height_pt:.1f}pt")

    # The selected tab is translucent over the headerless sidebar/page
    # background, so it is tab-like (blue-tinted) rather than neutral gray.
    # Before the fix the first tab started at the sidebar edge, leaving the
    # gray strip above the sidebar with no tab in it.
    y_values = range(band_top + int(6 * scale), band_bottom - int(6 * scale) + 1)
    y_count = max(1, len(y_values))
    column_hits = []
    for x in range(0, image.width):
        hits = sum(1 for y in y_values if is_tab_like(image.pixel(x, y)))
        column_hits.append(hits / y_count)
    selected_left = None
    run_start = None
    for x, fraction in enumerate(column_hits):
        if fraction >= 0.8:
            if run_start is None:
                run_start = x
            elif x - run_start >= 10 * scale:
                selected_left = run_start
                break
        else:
            run_start = None
    if selected_left is None:
        selected_left = 0 if column_hits and column_hits[0] >= 0.8 else None

    check(selected_left is not None, "realTabs.selectedTabFound")
    if selected_left is not None:
        selected_left_pt = selected_left / scale
        check(selected_left_pt <= 6, "realTabs.selectedTabStartsAtLeftEdge",
              f"left={selected_left_pt:.1f}pt")
        check(selected_left_pt < sidebar_width,
              "realTabs.tabSpansScaleSidebar",
              f"tab left={selected_left_pt:.1f}pt, sidebar={sidebar_width:g}pt")

    check(content_top >= band_bottom_pt - 1,
          "realTabs.contentBelowTabBar",
          f"contentTop={content_top:g}pt, tabBarBottom={band_bottom_pt:.1f}pt")
    check(sidebar_header_top >= band_bottom_pt - 1,
          "realTabs.sidebarBelowTabBar",
          f"sidebarHeaderTop={sidebar_header_top:g}pt, tabBarBottom={band_bottom_pt:.1f}pt")

    finish()


def finish():
    if FAILURES:
        print(f"{len(FAILURES)} tab geometry check(s) failed out of {CHECKS}:")
        for failure in FAILURES:
            print("  - " + failure)
        raise SystemExit(1)
    print(f"All {CHECKS} tab geometry checks passed.")


if __name__ == "__main__":
    main()
