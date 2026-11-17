#!/usr/bin/env python3
"""Verify Qdown's sidebar-priority tab strip on a real screen capture.

Qdown draws the tab strip itself inside the document column, so unlike the old
native titlebar tab bar it is visible in a `screencapture -l` image. The layout
contract is:

  * the sidebar owns the window's full height (traffic lights on top),
  * the tab strip starts exactly at the split position (never over the
    sidebar) and at the window's top edge (no blank band above the tabs),
  * every tab is on one row with the same height,
  * document content starts below the strip.

Both the geometry metadata written by the tabs harness and the actual pixels
are checked. Only the standard library is required. Pillow is used when
available; otherwise the PNG is converted to BMP with `sips` and decoded
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


def distance(a, b):
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]))


def close(a, b, tolerance=6):
    return distance(a, b) <= tolerance


def ink_rows(image, x0, x1, y0, y1, threshold=190):
    """Rows containing dark glyph pixels inside a light tab cell."""
    rows = []
    for y in range(y0, max(y0, y1)):
        for x in range(max(0, x0), max(0, x1)):
            red, green, blue = image.pixel(x, y)
            if (red + green + blue) / 3.0 < threshold:
                rows.append(y)
                break
    return rows


def ink_center(image, x0, x1, y0, y1):
    rows = ink_rows(image, x0, x1, y0, y1)
    if not rows:
        return None
    return (min(rows) + max(rows)) / 2.0


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
    chrome = metadata.get("chrome") or {}
    frame = parse_frame(metadata.get("windowFrame") or chrome.get("windowFrame"))
    if not frame:
        raise SystemExit("no windowFrame in metadata")
    _, _, window_width, window_height = frame

    tab_left = float(chrome.get("tabBarLeft", -1))
    tab_top = float(chrome.get("tabBarTop", -1))
    tab_height = float(chrome.get("tabBarHeight", -1))
    tab_width = float(chrome.get("tabBarWidth", -1))
    sidebar_width = float(chrome.get("sidebarWidth", -1))
    sidebar_right = float(chrome.get("sidebarRight", -1))
    content_left = float(chrome.get("contentLeft", -1))
    webview_top = float(chrome.get("webViewTop", -1))
    sidebar_header_top = float(chrome.get("sidebarHeaderTop", -1))
    tabs = chrome.get("tabBarTabs") or []

    image = load_image(screenshot)
    scale = image.width / window_width
    check(1.5 <= scale <= 3.0, "realTabs.captureScale", f"{scale:.3f}x")
    check(abs(image.height - window_height * scale) <= 3,
          "realTabs.captureSize",
          f"{image.width}x{image.height} for {window_width:g}x{window_height:g}pt")

    # ---- Metadata geometry --------------------------------------------------
    check(chrome.get("tabBarVisible") is True, "realTabs.tabBarVisible",
          str(chrome.get("tabBarVisible")))
    check(chrome.get("nativeTabBarVisible") is False,
          "realTabs.nativeTabBarHidden", str(chrome.get("nativeTabBarVisible")))
    check(abs(tab_top) <= 0.5, "realTabs.tabBarAtWindowTop", f"top={tab_top:g}pt")
    check(abs(tab_left - sidebar_right) <= 0.5, "realTabs.tabBarLeftAtSplit",
          f"left={tab_left:g}pt, sidebarRight={sidebar_right:g}pt")
    check(abs(content_left - (sidebar_right + 5)) <= 0.5,
          "realTabs.contentColumnAfterDivider",
          f"contentLeft={content_left:g}pt, sidebarRight={sidebar_right:g}pt")
    check(tab_left >= sidebar_width - 0.5, "realTabs.tabBarNeverOverSidebar",
          f"left={tab_left:g}pt, sidebar={sidebar_width:g}pt")
    check(abs((tab_left + tab_width) - window_width) <= 0.5,
          "realTabs.tabBarSpansDocumentColumn",
          f"right={tab_left + tab_width:g}pt, window={window_width:g}pt")
    check(abs(tab_height - 34) <= 0.5, "realTabs.tabBarHeight", f"{tab_height:g}pt")
    check(len(tabs) == 3, "realTabs.tabCount", f"{len(tabs)} tabs")
    check(bool(tabs) and all(abs(tab.get("top", -99)) <= 0.5 for tab in tabs),
          "realTabs.allTabsAtWindowTop", str([tab.get("top") for tab in tabs]))
    check(bool(tabs) and all(abs(tab.get("height", -99) - tab_height) <= 0.5 for tab in tabs),
          "realTabs.allTabsSameHeight", str([tab.get("height") for tab in tabs]))
    check(bool(tabs) and all(tab.get("left", -99) >= sidebar_right - 0.5 for tab in tabs),
          "realTabs.allTabsInsideDocumentColumn",
          str([tab.get("left") for tab in tabs]))
    check(webview_top >= tab_height - 0.5, "realTabs.contentBelowTabBar",
          f"webViewTop={webview_top:g}pt, tabBarHeight={tab_height:g}pt")
    check(sidebar_header_top == 28, "realTabs.sidebarFullHeight",
          f"sidebarHeaderTop={sidebar_header_top:g}pt")

    # ---- Title vertical centering (view hierarchy) -------------------------
    metrics = chrome.get("tabBarTitleMetrics") or []
    check(bool(tabs) and len(metrics) == len(tabs),
          "realTabs.titleMetricsPresent", f"{len(metrics)} metrics for {len(tabs)} tabs")
    if metrics:
        title_offsets = [float(item.get("titleCenterOffset", 999)) for item in metrics]
        close_offsets = [float(item.get("closeCenterOffset", 999)) for item in metrics]
        gaps = [abs(close - title) for title, close in zip(title_offsets, close_offsets)]
        check(all(abs(offset) <= 1.0 for offset in title_offsets),
              "realTabs.titleVerticallyCentered",
              f"title center offsets={[round(v, 2) for v in title_offsets]}pt, "
              f"close center offsets={[round(v, 2) for v in close_offsets]}pt")
        check(all(gap <= 1.0 for gap in gaps),
              "realTabs.closeCenteredWithTitle",
              f"title/close center gaps={[round(v, 2) for v in gaps]}pt")
        inside = all(
            float(item.get("titleTop", -99)) >= 0
            and float(item.get("titleTop", 999)) + float(item.get("titleHeight", 0))
            <= tab_height + 0.5
            for item in metrics
        )
        check(inside, "realTabs.titleInsideTabRow",
              f"titleTop={[round(float(item.get('titleTop', -99)), 2) for item in metrics]}pt")

    # ---- Pixel geometry -----------------------------------------------------
    # `screencapture` draws a few black pixels of window outline at the very
    # edge, so sample slightly inside the window.
    sidebar_color = image.pixel(10, image.height * 0.55)
    page_color = image.pixel(image.width - 20, image.height - 20)
    bar_color = image.pixel(image.width - 20, 3)

    # The top edge over the document column is the tab strip, not page color
    # and not an empty titlebar band.
    check(distance(bar_color, page_color) > 6,
          "realTabs.topEdgeIsTabBarNotPage",
          f"top={bar_color}, page={page_color}")
    check(distance(image.pixel(image.width - 20, 3), page_color) > 6,
          "realTabs.noBlankBandAboveTabs",
          f"y=3 -> {image.pixel(image.width - 20, 3)}")

    # Scan one row below the traffic lights. Everything left of the split must
    # still be sidebar; the first non-sidebar pixel must be the tab strip's
    # left edge.
    sample_y = int(30 * scale)
    split_px = int(round(sidebar_right * scale))
    left_pixels = [image.pixel(x, sample_y) for x in range(0, max(1, split_px - 2))]
    sidebar_like = sum(1 for pixel in left_pixels if close(pixel, sidebar_color, 7))
    check(sidebar_like >= len(left_pixels) * 0.97,
          "realTabs.noTabOverSidebar",
          f"{sidebar_like}/{len(left_pixels)} sidebar pixels")

    transition = None
    for x in range(0, image.width):
        if distance(image.pixel(x, sample_y), sidebar_color) > 7:
            transition = x
            break
    check(transition is not None, "realTabs.tabBarLeftEdgeFound")
    if transition is not None:
        check(abs(transition / scale - sidebar_right) <= 2.0,
              "realTabs.tabBarLeftEdgeAtSplit",
              f"edge={transition / scale:.1f}pt, split={sidebar_right:g}pt")

    # At the right edge the strip changes into the page exactly at the tab
    # strip's bottom edge.
    transition_y = None
    right_x = image.width - 20
    # Require a short run of page pixels so the anti-aliased window outline at
    # the very top is not mistaken for the start of the page.
    for y in range(0, int(image.height * 0.25)):
        if all(close(image.pixel(right_x, y + offset), page_color, 3)
               for offset in range(0, 5)):
            transition_y = y
            break
    check(transition_y is not None, "realTabs.pageBelowTabBarFound")
    if transition_y is not None:
        check(abs(transition_y / scale - tab_height) <= 3.0,
              "realTabs.pageStartsBelowTabBar",
              f"pageTop={transition_y / scale:.1f}pt, tabBarHeight={tab_height:g}pt")

    # Every tab starts at the same top edge and ends at the same bottom edge,
    # both in metadata and in the actual pixels.
    top_ok = True
    bottom_ok = True
    for index, tab in enumerate(tabs):
        center_x = int((tab["left"] + tab["width"] / 2) * scale)
        top_pixel = image.pixel(center_x, max(1, int(2 * scale)))
        if close(top_pixel, page_color, 5) or close(top_pixel, sidebar_color, 5):
            top_ok = False
        below_pixel = image.pixel(center_x, int((tab_height + 5) * scale))
        if not close(below_pixel, page_color, 8):
            bottom_ok = False
        print(f"    tab[{index}] center={center_x/scale:.1f}pt "
              f"top={top_pixel} below={below_pixel}")
    check(top_ok, "realTabs.allTabsShareTopRow")
    check(bottom_ok, "realTabs.allTabsShareBottomEdge")

    # ---- Title vertical centering (actual pixels) --------------------------
    # Measure the dark glyph ink rows inside each tab: the title text must be
    # centered on the tab row's vertical center, and the title ink must share
    # its center with the close glyph. The bottom 4pt are excluded because the
    # selected tab has a 2pt accent rule and every tab has a 1pt separator.
    bar_center_px = tab_height / 2.0 * scale
    ink_top = int(round(2 * scale))
    ink_bottom = int(round((tab_height - 4) * scale))
    for index, tab in enumerate(tabs):
        tab_left = float(tab["left"])
        tab_width = float(tab["width"])
        title_center = ink_center(
            image,
            int(round((tab_left + 14) * scale)),
            int(round((tab_left + max(0, tab_width - 40)) * scale)),
            ink_top, ink_bottom,
        )
        close_center = ink_center(
            image,
            int(round((tab_left + tab_width - 22) * scale)),
            int(round((tab_left + tab_width - 6) * scale)),
            ink_top, ink_bottom,
        )
        if title_center is None or close_center is None:
            check(False, f"realTabs.tab{index}.titleAndCloseInkFound",
                  f"title={title_center}, close={close_center}")
            continue
        title_offset = (title_center - bar_center_px) / scale
        close_offset = (close_center - bar_center_px) / scale
        gap = abs(title_center - close_center) / scale
        print(f"    tab[{index}] titleInkCenterOffset={title_offset:.2f}pt "
              f"closeInkCenterOffset={close_offset:.2f}pt gap={gap:.2f}pt")
        check(abs(title_offset) <= 3.0,
              f"realTabs.tab{index}.titleInkVerticallyCentered",
              f"offset={title_offset:.2f}pt")
        check(gap <= 2.5,
              f"realTabs.tab{index}.titleAndCloseSameHeight",
              f"gap={gap:.2f}pt")

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
