#!/usr/bin/env python3
"""Assert Qdown's automated verification results.

The suite covers Markdown rendering, the shared theme, find, the floating
outline (method A), AppKit's native window tabs, and the headerless window.
"""
import hashlib
import json
import plistlib
import sys
from pathlib import Path

FAILURES = []
CHECKS = 0
RESULTS = []


def check(condition, label, detail=""):
    global CHECKS
    CHECKS += 1
    ok = bool(condition)
    RESULTS.append((label, ok, detail))
    if not ok:
        FAILURES.append(f"{label}: {detail}" if detail else label)


def load_json_with_prefix(path, prefix):
    text = Path(path).read_text()
    index = text.find("{")
    if index < 0:
        raise SystemExit(f"no JSON in {path}")
    return json.loads(text[index:])


def load_outline(value):
    """The harness stores outlineDebug() as a JSON string."""
    if isinstance(value, dict):
        return value
    try:
        return json.loads(value or "{}")
    except (TypeError, ValueError):
        return {}


def check_outline_headings(outline, prefix, expected=None):
    check(outline.get("present") is True, f"{prefix}.outlinePresent")
    check(outline.get("insideContent") is False, f"{prefix}.outlineOutsideContent",
          str(outline.get("insideContent")))
    check(outline.get("barCount") == outline.get("headingCount"),
          f"{prefix}.outlineBarCount",
          f"{outline.get('barCount')} != {outline.get('headingCount')}")
    check(outline.get("itemCount") == outline.get("headingCount"),
          f"{prefix}.outlineItemCount",
          f"{outline.get('itemCount')} != {outline.get('headingCount')}")
    if expected is not None:
        check(outline.get("headingCount") == expected, f"{prefix}.outlineHeadingCount",
              str(outline.get("headingCount")))
    check(outline.get("userSelect") == "none", f"{prefix}.outlineUserSelectNone",
          str(outline.get("userSelect")))
    check(all(width > 0 for width in outline.get("barWidths", [])),
          f"{prefix}.outlineBarsHaveWidth", str(outline.get("barWidths")))


def main():
    out = Path(sys.argv[1])
    root = out.parent.parent
    app = root / "build" / "Release" / "Qdown.app"

    render = json.loads((out / "render.json").read_text())
    fallback = json.loads((out / "render-fallback.json").read_text())
    security = json.loads((out / "security.json").read_text())
    smoke_two = load_json_with_prefix(out / "smoke-two.stdout", "QDOWNSMOKE")
    smoke_zoom = load_json_with_prefix(out / "smoke-zoom.stdout", "QDOWNSMOKE")
    smoke_link = load_json_with_prefix(out / "smoke-link.stdout", "QDOWNSMOKE")
    tabs = json.loads((out / "tabs.json").read_text())
    tabs_screen = json.loads((out / "tabs-screen.json").read_text())
    live_tabs = json.loads((out / "live-tabs.json").read_text())
    outline_screen = json.loads((out / "outline-screen.json").read_text())
    single_screen = json.loads((out / "single-screen.json").read_text())

    # ---- Markdown rendering -------------------------------------------------
    initial = render["initial"]
    check(initial["rendered"] is True, "render.rendered")
    check(initial["headingCount"] >= 16, "render.headingCount", str(initial["headingCount"]))
    check(initial["tableCount"] >= 1, "render.tableCount", str(initial["tableCount"]))
    check(initial["taskCheckboxCount"] == 4, "render.taskCheckboxCount", str(initial["taskCheckboxCount"]))
    check(initial["checkedCheckboxCount"] == 2, "render.checkedCheckboxCount", str(initial["checkedCheckboxCount"]))
    check(initial["codeBlockCount"] >= 6, "render.codeBlockCount", str(initial["codeBlockCount"]))
    check(initial["highlightedBlockCount"] >= 5, "render.highlightedBlockCount", str(initial["highlightedBlockCount"]))
    check(initial["tokenCount"] >= 30, "render.tokenCount", str(initial["tokenCount"]))
    check(initial["blockquoteCount"] >= 2, "render.blockquoteCount", str(initial["blockquoteCount"]))
    check(initial["hrCount"] >= 1, "render.hrCount", str(initial["hrCount"]))
    check(initial["imageCount"] == 1, "render.imageCount", str(initial["imageCount"]))
    check(initial["imageLoadedCount"] == 1, "render.imageLoadedCount", str(initial["imageLoadedCount"]))
    check(initial["imageNaturalWidths"] == [360], "render.imageNaturalWidths", str(initial["imageNaturalWidths"]))
    check(initial["blockedImageCount"] == 0, "render.blockedImageCount", str(initial["blockedImageCount"]))
    check(initial["nonLocalImageCount"] == 0, "render.nonLocalImageCount", str(initial["nonLocalImageCount"]))
    check(initial["mermaidBlockCount"] == 3, "render.mermaidBlockCount", str(initial["mermaidBlockCount"]))
    check(initial["mermaidSvgCount"] == 3, "render.mermaidSvgCount", str(initial["mermaidSvgCount"]))
    check(initial["mermaidErrorCount"] == 0, "render.mermaidErrorCount", str(initial["mermaidErrorCount"]))
    check(initial["linkCount"] == 3, "render.linkCount", str(initial["linkCount"]))
    check(initial["externalLinkCount"] == 1, "render.externalLinkCount", str(initial["externalLinkCount"]))
    check(initial["errors"] == [], "render.errors", str(initial["errors"]))
    check(render["logs"] == [], "render.logs", str(render["logs"]))
    check(render["requestedResources"], "render.requestedResources empty")
    check(all(url.startswith("qdown://") for url in render["requestedResources"]),
          "render.requestedResources non-qdown", str(render["requestedResources"]))

    # ---- Floating outline (static) -----------------------------------------
    initial_outline = initial.get("outline", {})
    check_outline_headings(initial_outline, "render.initial", 16)
    check(initial_outline.get("activeIndex") == 0, "render.initial.outlineActiveFirst",
          str(initial_outline.get("activeIndex")))
    check(initial_outline.get("activeId") == "qdown-heading-0",
          "render.initial.outlineActiveFirstId", str(initial_outline.get("activeId")))
    bar_widths = initial_outline.get("rectEffectiveBarWidths", [])
    check(len(bar_widths) == initial_outline.get("headingCount"),
          "render.initial.outlineWidthCount", str(len(bar_widths)))
    check(len({round(width, 1) for width in bar_widths}) >= 3,
          "render.initial.outlineLevelWidths", str(bar_widths[:8]))
    check(len(set(initial_outline.get("levels", []))) >= 4,
          "render.initial.outlineLevels", str(initial_outline.get("levels")))
    check(abs(initial_outline.get("outlineRight", 0)
              - initial_outline.get("bodyRight", 0)) <= 2.0,
          "render.initial.outlineAtTextRightEdge",
          f"outlineRight={initial_outline.get('outlineRight')}, "
          f"bodyRight={initial_outline.get('bodyRight')}")
    check(abs(initial_outline.get("outlineHeight", 0)
              - initial_outline.get("viewportHeight", 0)
              * initial_outline.get("pageZoom", 1)) <= 2.0,
          "render.initial.outlineFullHeight",
          f"{initial_outline.get('outlineHeight')} vs "
          f"{initial_outline.get('viewportHeight')}*{initial_outline.get('pageZoom')}")
    check(initial_outline.get("compact") is False,
          "render.initial.outlineNotCompact", str(initial_outline.get("compact")))

    # ---- Theme colours ------------------------------------------------------
    theme = initial["theme"]
    expected_theme = {
        "bodyBackground": "rgb(240, 240, 247)",
        "h1Color": "rgb(112, 86, 151)",
        "h2Color": "rgb(112, 86, 151)",
        "linkColor": "rgb(112, 86, 151)",
        "inlineCodeColor": "rgb(122, 62, 157)",
        "inlineCodeBackground": "rgb(237, 237, 245)",
        "codeBlockBackground": "rgb(242, 242, 242)",
        "blockquoteBackground": "rgb(237, 237, 245)",
        "blockquoteBorder": "rgb(112, 86, 151)",
        "tableHeaderBackground": "rgb(237, 237, 245)",
        "tableHeaderColor": "rgb(112, 86, 151)",
        "taskCheckboxAccent": "rgb(112, 86, 151)",
        "h1Border": "rgb(196, 183, 215)",
    }
    for key, value in expected_theme.items():
        check(theme.get(key) == value, f"theme.{key}", f"{theme.get(key)} != {value}")
    check("Hiragino" in theme.get("bodyFont", ""), "theme.bodyFont", theme.get("bodyFont", ""))

    mermaid_theme = initial["mermaidTheme"]
    check(mermaid_theme.get("nodeFill") == "rgb(237, 237, 245)",
          "mermaid.nodeFill", str(mermaid_theme.get("nodeFill")))
    check(mermaid_theme.get("nodeStroke") == "rgb(112, 86, 151)",
          "mermaid.nodeStroke", str(mermaid_theme.get("nodeStroke")))
    check(mermaid_theme.get("labelFill") == "rgb(51, 51, 51)",
          "mermaid.labelFill", str(mermaid_theme.get("labelFill")))
    check(mermaid_theme.get("edgeStroke") == "rgb(112, 86, 151)",
          "mermaid.edgeStroke", str(mermaid_theme.get("edgeStroke")))

    # ---- Search -------------------------------------------------------------
    first_find = render["find"]["first"]["find"]
    next_find = render["find"]["next"]["find"]
    zero_find = render["find"]["zero"]["find"]
    check(first_find["count"] >= 8, "find.count", str(first_find["count"]))
    check(first_find["current"] == 1, "find.current", str(first_find["current"]))
    check(first_find["mode"] == "css-highlight", "find.mode", first_find["mode"])
    check(next_find["current"] == 2, "find.next.current", str(next_find["current"]))
    check(zero_find["count"] == 0, "find.zero.count", str(zero_find["count"]))

    # The outline is outside #content, so find must never match its labels.
    check(render["find"]["first"].get("outline", {}).get("findRangesInsideOutline") == 0,
          "find.outlineNotSearched",
          str(render["find"]["first"].get("outline", {}).get("findRangesInsideOutline")))

    fb_first = fallback["find"]["first"]
    check(fb_first["find"]["mode"] == "mark", "fallback.mode", fb_first["find"]["mode"])
    check(fb_first["markCount"] >= 8, "fallback.markCount", str(fb_first["markCount"]))
    check(fb_first["find"]["count"] == fb_first["markCount"], "fallback.count==marks")

    # ---- Responsive ---------------------------------------------------------
    check(initial["layout"]["overflowX"] is False, "layout.initial.overflowX")
    for name, width in (("narrow", 520), ("compact", 380), ("wide", 1400)):
        section = render[name]
        check(section["layout"]["innerWidth"] == width, f"layout.{name}.width",
              str(section["layout"]["innerWidth"]))
        check(section["layout"]["overflowX"] is False, f"layout.{name}.overflowX")
        check(section["layout"]["mermaidOverflow"] is False, f"layout.{name}.mermaidOverflow")
        check(section["layout"]["mermaidWidth"] <= section["layout"]["contentWidth"] + 1,
              f"layout.{name}.mermaidWidth")
    check(render["compact"]["layout"]["contentWidth"] < render["narrow"]["layout"]["contentWidth"],
          "layout.compact narrower than narrow")

    # Narrow windows use the 6-8pt bar variant and stay inside the page.
    narrow_outline = render["narrow"].get("outline", {})
    check(narrow_outline.get("compact") is True, "outline.narrow.compact",
          str(narrow_outline.get("compact")))
    check(max(narrow_outline.get("rectEffectiveBarWidths") or [99]) <= 8.5,
          "outline.narrow.barWidth", str(narrow_outline.get("rectEffectiveBarWidths")))
    check(min(narrow_outline.get("barRightGaps") or [0]) >= 0,
          "outline.narrow.barsInsideWindow", str(narrow_outline.get("barRightGaps")))
    check(render["wide"].get("outline", {}).get("compact") is False,
          "outline.wide.notCompact")

    # ---- Links / heading jump ----------------------------------------------
    check(render["headingScroll"]["layout"]["bodyScrollY"] > 0,
          "headingScroll.scrollY", str(render["headingScroll"]["layout"]["bodyScrollY"]))
    check("Tests/fixtures/other.md" in render["linkEvents"],
          "linkEvents.local", str(render["linkEvents"]))
    check("https://example.com/" in render["linkEvents"],
          "linkEvents.external", str(render["linkEvents"]))
    check(render["linkInfo"]["href"].startswith("qdown://app/viewer.html"),
          "linkInfo.stayedOnViewer", str(render["linkInfo"]))

    # ---- Floating outline (behaviour) --------------------------------------
    target = render["headingScroll"].get("targetHeading")
    after_scroll = render["outlineAfterScroll"].get("outline", {})
    check(after_scroll.get("activeId") == target, "outline.scroll.activeFollowsHeading",
          f"{after_scroll.get('activeId')} != {target}")
    check(render["outlineAfterScroll"]["layout"]["bodyScrollY"] > 0,
          "outline.scroll.scrollY")

    click = render["outlineClick"]
    clicked_index = click.get("clickedIndex", -1)
    check(clicked_index == 3, "outline.click.barClicked", str(clicked_index))
    check(click.get("outline", {}).get("activeIndex") == clicked_index,
          "outline.click.activeFollowsBar", str(click.get("outline", {}).get("activeIndex")))
    clicked_top = click.get("targetHeadingTop", -9999)
    check(isinstance(clicked_top, (int, float)) and -8 <= clicked_top <= 60,
          "outline.click.headingNearTop", str(clicked_top))
    check(click.get("scrollY", 0) > 0, "outline.click.scrolled", str(click.get("scrollY")))

    expanded = render["outlineExpanded"].get("outline", {})
    check(expanded.get("expanded") is True, "outline.panel.expanded")
    check(expanded.get("panelVisible") is True, "outline.panel.visible")
    check(120 <= expanded.get("panelWidth", 0) <= 260, "outline.panel.width",
          str(expanded.get("panelWidth")))
    check(expanded.get("panelHeight", 0) <= expanded.get("viewportHeight", 0) * 0.66,
          "outline.panel.height", str(expanded.get("panelHeight")))
    check(expanded.get("userSelect") == "none", "outline.panel.userSelectNone")

    # ---- Floating outline (zoom invariance) --------------------------------
    zooms = render["outlineZooms"]
    check(set(zooms.keys()) == {"0.50", "1.00", "1.25", "2.50"},
          "outline.zoom.cases", str(sorted(zooms.keys())))
    baseline = zooms.get("1.00", {}).get("outline", {}).get("rectEffectiveBarWidths", [])
    check(bool(baseline), "outline.zoom.baseline")
    for key in ("0.50", "1.00", "1.25", "2.50"):
        entry = zooms.get(key, {})
        outline = entry.get("outline", {})
        widths = outline.get("rectEffectiveBarWidths", [])
        check(len(widths) == len(baseline)
              and all(abs(width - base) <= 0.6 for width, base in zip(widths, baseline)),
              f"outline.zoom.{key}.barWidthConstant", str(widths[:6]))
        gaps = outline.get("barRightGaps", [])
        check(bool(gaps) and all(gap > 0 for gap in gaps),
              f"outline.zoom.{key}.barsInsideViewport", str(gaps[:3]))
        check(entry.get("layout", {}).get("overflowX") is False,
              f"outline.zoom.{key}.noOverflow")

    # ---- Security fixture ---------------------------------------------------
    sec = security["security"]
    check(sec["pwned"] is False, "security.pwned")
    check(sec["scriptElements"] == 0, "security.scriptElements")
    check(sec["iframeElements"] == 0, "security.iframeElements")
    check(sec["javascriptHrefs"] == 0, "security.javascriptHrefs")
    check(sec["remoteImageSources"] == 0, "security.remoteImageSources")
    check(sec["externalResources"] == [], "security.externalResources")
    check(security["initial"]["blockedImageCount"] == 1, "security.blockedImageCount",
          str(security["initial"]["blockedImageCount"]))
    check(security["initial"]["imageLoadedCount"] == 1, "security.localImageLoaded",
          str(security["initial"]["imageLoadedCount"]))

    # ---- Native windows -----------------------------------------------------
    check(smoke_two["windowTitles"] == ["test.md", "other.md"],
          "smoke.windowTitles", str(smoke_two["windowTitles"]))
    check(smoke_two["visibleWindows"] == 2, "smoke.visibleWindows",
          str(smoke_two["visibleWindows"]))
    states = smoke_two["states"]
    check(states[0]["title"] == "test.md", "smoke.first.title", states[0]["title"])
    check(states[0]["outlineHeadingCount"] == 16, "smoke.first.outlineHeadingCount",
          str(states[0]["outlineHeadingCount"]))
    check(states[1]["title"] == "other.md", "smoke.second.title", states[1]["title"])
    check(states[1]["outlineHeadingCount"] >= 2, "smoke.second.outlineHeadingCount",
          str(states[1]["outlineHeadingCount"]))
    check(states[0]["pageZoom"] == 1.25, "smoke.zoomPersisted", str(states[0]["pageZoom"]))

    # ---- Headerless chrome (single window, no native tab bar) --------------
    chrome = states[0]
    check(chrome.get("fullSizeContentView") is True, "chrome.fullSizeContentView")
    check(chrome.get("titlebarAppearsTransparent") is True,
          "chrome.titlebarAppearsTransparent")
    check(chrome.get("titleVisibilityHidden") is True, "chrome.titleVisibilityHidden",
          str(chrome.get("titleVisibilityHidden")))
    check(chrome.get("titlebarSeparatorStyleNone") is True,
          "chrome.titlebarSeparatorStyleNone", str(chrome.get("titlebarSeparatorStyle")))
    safe_top = chrome.get("contentSafeAreaTop", -1)
    check(safe_top == 28, "chrome.contentSafeAreaTop", str(safe_top))
    check(chrome.get("titlebarHeight", -1) == safe_top, "chrome.titlebarHeight",
          str(chrome.get("titlebarHeight")))
    check(chrome.get("tabBarVisible") is False, "chrome.nativeTabBarHidden",
          str(chrome.get("tabBarVisible")))
    check(chrome.get("nativeTabBarVisible") is False, "chrome.nativeTabBarHiddenAlias",
          str(chrome.get("nativeTabBarVisible")))
    check(chrome.get("contentDragRegionAcceptsMouse") is True,
          "chrome.contentDragRegionAcceptsMouse")
    check(chrome.get("webViewTop", -1) >= safe_top, "chrome.webViewTop",
          str(chrome.get("webViewTop")))
    check(chrome.get("findBarTop", -1) >= safe_top, "chrome.findBarTop",
          str(chrome.get("findBarTop")))
    check(chrome.get("title") == "test.md", "chrome.filenameStillAvailable",
          str(chrome.get("title")))

    extras = states[-1]
    check(extras["zoomIn"] == 1.5, "smoke.zoomIn", str(extras["zoomIn"]))
    check(extras["actualSize"] == 1, "smoke.actualSize", str(extras["actualSize"]))
    check(extras["persistedZoomAfterReset"] == 1, "smoke.persistedZoomAfterReset")

    smoke_outline = load_outline(extras.get("outline"))
    check_outline_headings(smoke_outline, "smoke")
    check(extras.get("outlineClick") is True, "smoke.outlineClick")
    after_click = load_outline(extras.get("outlineAfterClick"))
    check(after_click.get("activeIndex") == after_click.get("headingCount", 0) - 1,
          "smoke.outlineActiveAfterClick", str(after_click.get("activeIndex")))

    # ---- Cross-process zoom persistence -------------------------------------
    zoom_states = smoke_zoom["states"]
    zoom_extras = zoom_states[-1]
    check(zoom_states[0]["pageZoom"] == 1.25, "smokeZoom.pageZoom",
          str(zoom_states[0]["pageZoom"]))
    check(zoom_extras["zoomReadOnly"] is True, "smokeZoom.readOnly")
    check(zoom_extras["persistedZoomAtLaunch"] == 1.25, "smokeZoom.persistedAtLaunch",
          str(zoom_extras["persistedZoomAtLaunch"]))
    check(zoom_extras["actualSize"] == 1, "smokeZoom.resetToActualSize",
          str(zoom_extras["actualSize"]))
    check(extras["findBarVisibleAfterFind"] is True, "smoke.findBarVisibleAfterFind")
    check(extras["findBarVisibleAfterEscape"] is False, "smoke.findBarVisibleAfterEscape")
    check(extras["findCountText"] == "1/8 件", "smoke.findCountText", extras["findCountText"])
    check(extras["findCountTextAfterNext"] == "2/8 件", "smoke.findNext",
          extras["findCountTextAfterNext"])
    check(extras["findCountTextAfterPrevious"] == "1/8 件", "smoke.findPrevious",
          extras["findCountTextAfterPrevious"])
    check(extras["linkRouter"]["https://example.com/"].startswith("external:"),
          "smoke.linkRouter.https", extras["linkRouter"]["https://example.com/"])
    check(extras["linkRouter"]["javascript:alert(1)"] == "unsupported",
          "smoke.linkRouter.javascript", extras["linkRouter"]["javascript:alert(1)"])
    check(extras["linkRouter"]["Tests/fixtures/other.md"].startswith("local:"),
          "smoke.linkRouter.local", extras["linkRouter"]["Tests/fixtures/other.md"])
    for key in ("utf8", "shiftJIS", "eucJP", "utf16LEWithBOM"):
        check(extras["textDecoder"][key] == "日本語テキスト",
              f"smoke.textDecoder.{key}", extras["textDecoder"][key])

    check(smoke_link["states"][-1]["documentCount"] == 1, "smokeLink.documentCount")
    link_state = smoke_link["states"][-1]
    check(link_state.get("localLinkDocumentWindowCount") == 1,
          "smokeLink.sameWindow",
          str(link_state.get("localLinkDocumentWindowCount")))
    check(link_state.get("localLinkTabTitles") == ["other.md", "test.md"],
          "smokeLink.tabTitles", str(link_state.get("localLinkTabTitles")))

    # ---- Native window tabs -------------------------------------------------
    opened = tabs["opened"]
    check(tabs["automaticTabbing"] is False, "tabs.automaticTabbingDisabled")
    check(opened["tabCount"] == 2, "tabs.tabCount", str(opened["tabCount"]))
    check(opened["titles"] == ["other.md", "test.md"], "tabs.titles", str(opened["titles"]))
    check(opened["documentWindowCount"] == 1, "tabs.documentWindowCount",
          str(opened["documentWindowCount"]))
    check(opened["tabBarVisible"] is True, "tabs.nativeTabBarVisible")
    check(opened.get("nativeTabBarVisible") is True, "tabs.nativeTabBarVisibleAlias",
          str(opened.get("nativeTabBarVisible")))

    # AppKit's native tab bar is a titlebar row: it spans the whole window and
    # pushes the document down by the extra safe-area inset. There is no custom
    # tab strip or sidebar anymore.
    tabs_chrome = opened.get("chrome", {})
    tab_safe_top = tabs_chrome.get("contentSafeAreaTop", -1)
    check(tabs_chrome.get("nativeTabBarVisible") is True, "tabs.chrome.nativeTabBarVisible")
    check(tabs_chrome.get("fullSizeContentView") is True, "tabs.chrome.fullSizeContentView")
    check(tabs_chrome.get("titlebarAppearsTransparent") is True,
          "tabs.chrome.titlebarAppearsTransparent")
    check(tabs_chrome.get("titleVisibilityHidden") is True,
          "tabs.chrome.titleVisibilityHidden")
    check(tabs_chrome.get("titlebarSeparatorStyleNone") is True,
          "tabs.chrome.titlebarSeparatorStyleNone", str(tabs_chrome.get("titlebarSeparatorStyle")))
    check(tab_safe_top > 28, "tabs.chrome.safeAreaTop", str(tab_safe_top))
    check(tabs_chrome.get("titlebarHeight", -1) == tab_safe_top,
          "tabs.chrome.titlebarHeight", str(tabs_chrome.get("titlebarHeight")))
    check(tabs_chrome.get("webViewTop", -1) >= tab_safe_top - 0.5,
          "tabs.chrome.webViewClearOfTabBar", str(tabs_chrome.get("webViewTop")))
    check(tabs_chrome.get("contentDragRegionAcceptsMouse") is True,
          "tabs.chrome.contentDragRegionAcceptsMouse")
    check(tabs_chrome.get("title") in opened.get("titles", []),
          "tabs.chrome.filenameStillAvailable", str(tabs_chrome.get("title")))

    per_tab = opened.get("perTab", [])
    check({entry["title"] for entry in per_tab} == {"test.md", "other.md"},
          "tabs.perTabTitles", str([entry.get("title") for entry in per_tab]))
    check(all(entry["tabTitle"] == entry["title"] for entry in per_tab),
          "tabs.tabTitleMatchesWindowTitle", str(per_tab))
    check(all(entry["outlineHeadingCount"] > 0 for entry in per_tab),
          "tabs.perTabOutlineHeadings", str(per_tab))

    scroll = tabs["scroll"]
    check(scroll.get("before", 0) > 0, "tabs.scrollBefore", str(scroll.get("before")))
    check(scroll.get("preserved") is True, "tabs.scrollPreserved", str(scroll))

    local_link = tabs["localLink"]
    check(local_link.get("rendered") is True, "tabs.localLink.rendered")
    check(local_link.get("tabCount") == 3, "tabs.localLink.tabCount",
          str(local_link.get("tabCount")))
    check(local_link.get("titles") == ["other.md", "security.md", "test.md"],
          "tabs.localLink.titles", str(local_link.get("titles")))
    check(local_link.get("documentWindowCount") == 1, "tabs.localLink.sameWindow",
          str(local_link.get("documentWindowCount")))
    check(all(entry["outlineHeadingCount"] > 0 for entry in local_link.get("perTab", [])),
          "tabs.localLink.perTabOutlineHeadings", str(local_link.get("perTab")))

    # ---- Real-screen tab bar capture ----------------------------------------
    check(tabs_screen.get("mode") == "tabs-screen", "tabsScreen.mode",
          str(tabs_screen.get("mode")))
    screen_chrome = tabs_screen.get("chrome", {})
    check(tabs_screen.get("windowNumber", -1) > 0, "tabsScreen.windowNumber",
          str(tabs_screen.get("windowNumber")))
    check(screen_chrome.get("nativeTabBarVisible") is True, "tabsScreen.nativeTabBarVisible")
    check(screen_chrome.get("contentSafeAreaTop", -1) > 28,
          "tabsScreen.safeAreaTop", str(screen_chrome.get("contentSafeAreaTop")))
    check(screen_chrome.get("webViewTop", -1) >= screen_chrome.get("contentSafeAreaTop", 0) - 0.5,
          "tabsScreen.webViewClearOfTabBar", str(screen_chrome.get("webViewTop")))

    detach = tabs["detach"]
    check(detach.get("tabCountAfterDetach") == 2, "tabs.detach.tabCount",
          str(detach.get("tabCountAfterDetach")))
    check(detach.get("documentWindowCountAfterDetach") == 2,
          "tabs.detach.documentWindowCount",
          str(detach.get("documentWindowCountAfterDetach")))
    check(detach.get("tabCountAfterMerge") == 3, "tabs.merge.tabCount",
          str(detach.get("tabCountAfterMerge")))
    check(detach.get("documentWindowCountAfterMerge") == 1,
          "tabs.merge.documentWindowCount",
          str(detach.get("documentWindowCountAfterMerge")))

    for selector in ("toggleTabBar:", "moveTabToNewWindow:", "mergeAllWindows:", "selectNextTab:"):
        check(selector in tabs["menuActions"], f"tabs.menu.{selector}")

    # Closing tabs (2 -> 1) must restore the headerless, no-tab-bar layout.
    tab_close = tabs.get("tabClose", {})
    close_chrome = tab_close.get("chrome", {})
    check(tab_close.get("tabCountAfterClose") == 1, "tabs.close.tabCount",
          str(tab_close.get("tabCountAfterClose")))
    check(tab_close.get("tabBarVisibleAfterClose") is False,
          "tabs.close.nativeTabBarHidden",
          str(tab_close.get("tabBarVisibleAfterClose")))
    check(close_chrome.get("fullSizeContentView") is True,
          "tabs.close.fullSizeContentView")
    check(close_chrome.get("tabBarVisible") is False, "tabs.close.tabBarVisible",
          str(close_chrome.get("tabBarVisible")))
    check(close_chrome.get("nativeTabBarVisible") is False,
          "tabs.close.nativeTabBarHiddenAlias", str(close_chrome.get("nativeTabBarVisible")))
    check(close_chrome.get("contentSafeAreaTop") == 28,
          "tabs.close.safeAreaTop", str(close_chrome.get("contentSafeAreaTop")))
    check(close_chrome.get("titlebarHeight") == 28,
          "tabs.close.titlebarHeight", str(close_chrome.get("titlebarHeight")))
    check(close_chrome.get("webViewTop", -1) >= 28,
          "tabs.close.webViewTop", str(close_chrome.get("webViewTop")))
    check(close_chrome.get("contentDragRegionAcceptsMouse") is True,
          "tabs.close.contentDragRegionAcceptsMouse")

    # ---- Real LaunchServices (Finder double-click style) open events --------
    check(live_tabs["documentCount"] == 2, "liveTabs.documentCount",
          str(live_tabs["documentCount"]))
    check(sorted(live_tabs["documentURLs"]) == ["other.md", "test.md"],
          "liveTabs.documentURLs", str(live_tabs["documentURLs"]))
    check(live_tabs["documentWindowCount"] == 1, "liveTabs.documentWindowCount",
          str(live_tabs["documentWindowCount"]))
    check(live_tabs["tabCount"] == 2, "liveTabs.tabCount", str(live_tabs["tabCount"]))
    check(live_tabs["titles"] == ["other.md", "test.md"], "liveTabs.titles",
          str(live_tabs["titles"]))
    check(live_tabs["tabBarVisible"] is True, "liveTabs.nativeTabBarVisible")
    check(live_tabs.get("nativeTabBarVisible") is True, "liveTabs.nativeTabBarVisibleAlias",
          str(live_tabs.get("nativeTabBarVisible")))
    check(live_tabs.get("chrome", {}).get("contentSafeAreaTop", -1) > 28,
          "liveTabs.chrome.safeAreaTop",
          str(live_tabs.get("chrome", {}).get("contentSafeAreaTop")))
    live_per_tab = live_tabs.get("perTab", [])
    check({entry["title"] for entry in live_per_tab} == {"test.md", "other.md"},
          "liveTabs.perTabTitles", str([entry.get("title") for entry in live_per_tab]))
    check(all(entry["tabTitle"] == entry["title"] for entry in live_per_tab),
          "liveTabs.tabTitleMatchesWindowTitle", str(live_per_tab))
    check(all(entry["outlineHeadingCount"] > 0 for entry in live_per_tab),
          "liveTabs.perTabOutlineHeadings", str(live_per_tab))

    # ---- Real-screen single-window and outline-panel captures ---------------
    for label, capture in (("outlineScreen", outline_screen), ("singleScreen", single_screen)):
        check(capture.get("mode") == "window", f"{label}.mode", str(capture.get("mode")))
        capture_chrome = capture.get("chrome", {})
        check(capture.get("windowNumber", -1) > 0, f"{label}.windowNumber",
              str(capture.get("windowNumber")))
        check(capture_chrome.get("contentSafeAreaTop") == 28,
              f"{label}.safeAreaTop", str(capture_chrome.get("contentSafeAreaTop")))
        check(capture_chrome.get("nativeTabBarVisible") is False,
              f"{label}.nativeTabBarHidden",
              str(capture_chrome.get("nativeTabBarVisible")))
        capture_outline = load_outline(capture.get("outline"))
        check_outline_headings(capture_outline, label)
    check_outline_headings(load_outline(outline_screen.get("outline")),
                           "outlineScreen.expanded")
    screenshot_outline = load_outline(outline_screen.get("outline"))
    check(screenshot_outline.get("expanded") is True, "outlineScreen.panelExpanded")
    check(screenshot_outline.get("panelVisible") is True, "outlineScreen.panelVisible")

    # ---- Artifacts, CSS, Info.plist ----------------------------------------
    expected_css_hash = "5e33b8e7a578e0b5f93467ff7882c4314d1fcad9d3863ea0656151f0300477b6"
    source_css = (root / "Qdown" / "Resources" / "quiet-light.css").read_bytes()
    built_css = (app / "Contents" / "Resources" / "quiet-light.css").read_bytes()
    check(hashlib.sha256(source_css).hexdigest() == expected_css_hash, "css.sourceHash")
    check(hashlib.sha256(built_css).hexdigest() == expected_css_hash, "css.builtHash")
    check(source_css == built_css, "css.source==built")

    info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    doc_types = info.get("CFBundleDocumentTypes", [])
    extensions = {ext for entry in doc_types for ext in entry.get("CFBundleTypeExtensions", [])}
    check({"md", "markdown", "txt"} <= extensions, "info.extensions", str(extensions))
    check(any(entry.get("LSHandlerRank") == "Owner" and "md" in entry.get("CFBundleTypeExtensions", [])
              for entry in doc_types), "info.markdownOwner")

    for relative in (
        "Contents/Resources/vendor/marked.min.js",
        "Contents/Resources/vendor/highlight.min.js",
        "Contents/Resources/vendor/mermaid.min.js",
        "Contents/Resources/quiet-light.css",
        "Contents/Resources/viewer.html",
        "Contents/Resources/viewer.css",
        "Contents/Resources/viewer.js",
    ):
        path = app / relative
        check(path.is_file() and path.stat().st_size > 0, f"bundle.{relative}")

    for png in ("01-top.png", "02-mermaid.png", "03-section.png",
                "05-headerless-window.png", "06-headerless-content.png",
                "07-headerless-tabs-window.png", "08-headerless-tabs-content.png",
                "09-real-tabs-window.png", "10-outline-panel.png",
                "11-single-window.png"):
        path = out / png
        check(path.is_file() and path.stat().st_size > 1000, f"snapshot.{png}")

    # ---- Report -------------------------------------------------------------
    if "--verbose" in sys.argv:
        for label, ok, detail in RESULTS:
            suffix = f"  ({detail})" if (not ok and detail) else ""
            print(("PASS" if ok else "FAIL"), label + suffix)

    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed out of {CHECKS}:")
        for failure in FAILURES:
            print("  - " + failure)
        raise SystemExit(1)

    print(f"All {CHECKS} automated checks passed.")


if __name__ == "__main__":
    main()
