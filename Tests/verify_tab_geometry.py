#!/usr/bin/env python3
"""Verify a Qdown real-screen capture against its window metadata.

Qdown uses AppKit's native window tab bar. The layout contract is:

  * tabbed windows: the native tab bar spans the whole window, the
    headerless chrome is still transparent, and the document starts below
    the extra safe-area inset;
  * single-document windows: the tab bar is hidden and only the 28pt
    traffic-light strip remains (the page background reaches the top edge).

Both the metadata written by the harness and the actual pixels are checked.
Only the standard library is required. Pillow is used when available;
otherwise the PNG is converted to BMP with `sips` and decoded manually.
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
    # BI_RGB (0) is the classic layout. Newer `sips` builds write a 32-bit
    # BI_BITFIELDS (3) BMP with explicit channel masks; accept that too so the
    # fallback still works on machines without Pillow.
    if planes != 1 or depth not in (24, 32):
        raise ValueError(f"unsupported BMP: depth={depth} compression={compression}")
    masks = None
    if compression == 3:
        if depth != 32 or header_size < 56:
            raise ValueError(f"unsupported BMP: depth={depth} compression={compression}")
        red_mask, green_mask, blue_mask = struct.unpack_from("<III", data, 54)
        masks = (red_mask, green_mask, blue_mask)
    elif compression != 0:
        raise ValueError(f"unsupported BMP: depth={depth} compression={compression}")
    top_down = height < 0
    height = abs(height)
    row_bytes = ((width * depth + 31) // 32) * 4
    bytes_per_pixel = depth // 8

    def mask_channel(value, mask):
        if mask == 0:
            return 0
        shift = (mask & -mask).bit_length() - 1
        maximum = mask >> shift
        return ((value & mask) >> shift) * 255 // maximum

    def pixel(x, y):
        row = y if top_down else height - 1 - y
        index = offset + row * row_bytes + x * bytes_per_pixel
        if masks:
            value = int.from_bytes(data[index:index + 4], "little")
            return tuple(mask_channel(value, mask) for mask in masks)
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


def page_top(image, x, page_color, limit):
    """First y where five consecutive pixels match the page background."""
    for y in range(0, limit):
        if all(close(image.pixel(x, y + offset), page_color, 4)
               for offset in range(0, 5)):
            return y
    return None


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_tab_geometry.py <screenshot.png> <capture.json>")

    screenshot = Path(sys.argv[1])
    metadata_path = Path(sys.argv[2])
    if not screenshot.is_file() or screenshot.stat().st_size < 1000:
        raise SystemExit(f"missing or empty screenshot: {screenshot}")
    if not metadata_path.is_file():
        raise SystemExit(f"missing metadata: {metadata_path}")

    metadata = json.loads(metadata_path.read_text())
    chrome = metadata.get("chrome") or {}
    mode = metadata.get("mode") or ""
    frame = parse_frame(metadata.get("windowFrame") or chrome.get("windowFrame"))
    if not frame:
        raise SystemExit("no windowFrame in metadata")
    _, _, window_width, window_height = frame

    safe_top = float(chrome.get("contentSafeAreaTop", -1))
    titlebar_height = float(chrome.get("titlebarHeight", -1))
    webview_top = float(chrome.get("webViewTop", -1))
    tab_count = int(chrome.get("tabCount", 0))

    image = load_image(screenshot)
    scale = image.width / window_width
    check(1.5 <= scale <= 3.0, "realScreen.captureScale", f"{scale:.3f}x")
    check(abs(image.height - window_height * scale) <= 3,
          "realScreen.captureSize",
          f"{image.width}x{image.height} for {window_width:g}x{window_height:g}pt")
    check(metadata.get("windowNumber", -1) > 0, "realScreen.windowNumber",
          str(metadata.get("windowNumber")))
    check(chrome.get("fullSizeContentView") is True, "realScreen.fullSizeContentView")
    check(chrome.get("titlebarAppearsTransparent") is True,
          "realScreen.titlebarAppearsTransparent")
    check(chrome.get("titleVisibilityHidden") is True, "realScreen.titleVisibilityHidden")
    check(chrome.get("titlebarSeparatorStyleNone") is True,
          "realScreen.titlebarSeparatorStyleNone")

    limit = int(image.height * 0.25)
    page_color = image.pixel(image.width - 20, image.height - 20)
    left_x = int(image.width * 0.12)
    right_x = image.width - 20

    if mode == "tabs-screen":
        # ---- Native AppKit tab bar, full width ------------------------------
        check(chrome.get("nativeTabBarVisible") is True,
              "realTabs.nativeTabBarVisible")
        check(safe_top > 28, "realTabs.safeAreaTop", f"{safe_top:g}pt")
        check(abs(titlebar_height - safe_top) <= 0.5, "realTabs.titlebarHeight",
              f"{titlebar_height:g}pt vs safeTop {safe_top:g}pt")
        check(webview_top >= safe_top - 0.5, "realTabs.webViewClearOfTabBar",
              f"webViewTop={webview_top:g}pt")
        check(tab_count == 3, "realTabs.tabCount", f"{tab_count} tabs")

        # The transparent titlebar shares the page's lavender background, so
        # the tab bar is detected by its tab-title ink rather than by colour.
        # Titles are distributed across the full width: sample all three thirds
        # of the titlebar row.
        def title_ink(x0, x1):
            y0 = max(1, int(10 * scale))
            y1 = max(y0 + 1, int((safe_top - 8) * scale))
            for y in range(y0, y1):
                for x in range(max(0, int(x0)), min(image.width, int(x1))):
                    red, green, blue = image.pixel(x, y)
                    if (red + green + blue) / 3.0 < 190:
                        return True
            return False

        margin = int(image.width * 0.10)
        check(title_ink(margin, image.width * 0.36), "realTabs.titleInkLeftThird")
        check(title_ink(image.width * 0.36, image.width * 0.66),
              "realTabs.titleInkMiddleThird")
        check(title_ink(image.width * 0.66, image.width - margin),
              "realTabs.titleInkRightThird")
        check(title_ink(margin, image.width - margin),
              "realTabs.nativeTabBarRowHasTitles")
    else:
        # ---- Single document: 28pt headerless strip, no tab bar ------------
        check(chrome.get("tabBarVisible") is False, "realSingle.tabBarHidden",
              str(chrome.get("tabBarVisible")))
        check(chrome.get("nativeTabBarVisible") is False,
              "realSingle.nativeTabBarHidden", str(chrome.get("nativeTabBarVisible")))
        check(safe_top == 28, "realSingle.safeAreaTop", f"{safe_top:g}pt")
        check(titlebar_height == 28, "realSingle.titlebarHeight",
              f"{titlebar_height:g}pt")
        check(webview_top >= 28 - 0.5, "realSingle.webViewTop",
              f"webViewTop={webview_top:g}pt")
        top_center = image.pixel(image.width // 2, max(1, int(6 * scale)))
        check(close(top_center, page_color, 8), "realSingle.headerlessPageAtTopEdge",
              f"top={top_center}, page={page_color}")
        check(chrome.get("contentDragRegionAcceptsMouse") is True,
              "realSingle.dragRegionAcceptsMouse")
        check(chrome.get("contentDragRegionHitIsDragHandle") is True,
              "realSingle.dragRegionHitIsDragHandle")
        check(chrome.get("contentDragRegionTopInWindow", -1) == 0,
              "realSingle.dragRegionTopInWindow",
              f"{chrome.get('contentDragRegionTopInWindow')}")
        check(chrome.get("contentDragRegionHeight", -1) == 28,
              "realSingle.dragRegionHeight",
              f"{chrome.get('contentDragRegionHeight')}")
        check(chrome.get("contentDragRegionHandoff") == "screenDelta",
              "realSingle.dragRegionHandoff",
              str(chrome.get("contentDragRegionHandoff")))

    finish()


def finish():
    if FAILURES:
        print(f"{len(FAILURES)} real-screen check(s) failed out of {CHECKS}:")
        for failure in FAILURES:
            print("  - " + failure)
        raise SystemExit(1)
    print(f"All {CHECKS} real-screen checks passed.")


if __name__ == "__main__":
    main()
