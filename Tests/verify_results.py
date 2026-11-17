#!/usr/bin/env python3
"""Assert Qdown's automated verification results."""
import hashlib
import json
import plistlib
import re
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


def parse_window_size(text):
    """Parse an AppKit `{1120, 808}` size string."""
    match = re.match(r"\{\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\}", text or "")
    if not match:
        return None
    return float(match.group(1)), float(match.group(2))


def check_document_tab_strip(chrome, prefix, expected_count):
    """Assert the sidebar-priority custom tab strip geometry.

    * the strip starts at the split position (never over the sidebar),
    * its top is the window's top edge (no blank band above the tabs),
    * every tab is on the same single row with the same height.
    """
    check(chrome.get("tabBarVisible") is True, f"{prefix}.tabBarVisible")
    check(chrome.get("nativeTabBarVisible") is False,
          f"{prefix}.nativeTabBarHidden", str(chrome.get("nativeTabBarVisible")))
    check(chrome.get("tabBarTabCount") == expected_count,
          f"{prefix}.tabBarTabCount", str(chrome.get("tabBarTabCount")))

    left = chrome.get("tabBarLeft", -1)
    top = chrome.get("tabBarTop", -1)
    height = chrome.get("tabBarHeight", -1)
    width = chrome.get("tabBarWidth", -1)
    content_left = chrome.get("contentLeft", -1)
    sidebar_right = chrome.get("sidebarRight", -1)
    sidebar_width = chrome.get("sidebarWidth", -1)
    window_size = parse_window_size(chrome.get("windowSize"))
    window_width = window_size[0] if window_size else -1

    check(abs(top) <= 0.5, f"{prefix}.tabBarAtWindowTop", f"top={top:g}")
    check(abs(left - sidebar_right) <= 0.5, f"{prefix}.tabBarLeftAtSplit",
          f"left={left:g}, sidebarRight={sidebar_right:g}")
    check(abs(content_left - (sidebar_right + 5)) <= 0.5,
          f"{prefix}.contentColumnAfterDivider",
          f"contentLeft={content_left:g}, sidebarRight={sidebar_right:g}")
    check(abs(sidebar_right - sidebar_width) <= 0.5, f"{prefix}.splitAtSidebarWidth",
          f"sidebarRight={sidebar_right:g}, sidebarWidth={sidebar_width:g}")
    check(left >= sidebar_width - 0.5, f"{prefix}.tabBarNeverOverSidebar",
          f"left={left:g}, sidebar={sidebar_width:g}")
    check(abs(height - 34) <= 0.5, f"{prefix}.tabBarHeight", f"{height:g}pt")
    check(window_width > 0 and abs((left + width) - window_width) <= 0.5,
          f"{prefix}.tabBarSpansDocumentColumn",
          f"right={left + width:g}, windowWidth={window_width:g}")
    check(chrome.get("contentSafeAreaTop") == 28,
          f"{prefix}.nativeTabBarRemoved", str(chrome.get("contentSafeAreaTop")))
    check(chrome.get("sidebarHeaderTop") == 28,
          f"{prefix}.sidebarFullHeight", str(chrome.get("sidebarHeaderTop")))
    check(chrome.get("webViewTop", -1) >= height - 0.5,
          f"{prefix}.contentBelowTabBar",
          f"webViewTop={chrome.get('webViewTop')}, tabBarHeight={height:g}")

    tabs = chrome.get("tabBarTabs", [])
    check(len(tabs) == expected_count, f"{prefix}.tabFramesCount", str(len(tabs)))
    check(bool(tabs) and all(abs(tab.get("top", -99)) <= 0.5 for tab in tabs),
          f"{prefix}.allTabsAtWindowTop",
          str([tab.get("top") for tab in tabs]))
    check(bool(tabs) and all(abs(tab.get("height", -99) - height) <= 0.5 for tab in tabs),
          f"{prefix}.allTabsSameHeight",
          str([tab.get("height") for tab in tabs]))
    check(bool(tabs) and all(tab.get("left", -99) >= sidebar_right - 0.5 for tab in tabs),
          f"{prefix}.allTabsInsideDocumentColumn",
          str([tab.get("left") for tab in tabs]))
    if window_width > 0:
        check(bool(tabs) and all(tab.get("left", 0) + tab.get("width", 0)
                                 <= window_width + 0.5 for tab in tabs),
              f"{prefix}.allTabsWithinWindow",
              str([(tab.get("left"), tab.get("width")) for tab in tabs]))


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

    # ---- Links / heading jump ----------------------------------------------
    check(render["headingScroll"]["layout"]["bodyScrollY"] > 0,
          "headingScroll.scrollY", str(render["headingScroll"]["layout"]["bodyScrollY"]))
    check("Tests/fixtures/other.md" in render["linkEvents"],
          "linkEvents.local", str(render["linkEvents"]))
    check("https://example.com/" in render["linkEvents"],
          "linkEvents.external", str(render["linkEvents"]))
    check(render["linkInfo"]["href"].startswith("qdown://app/viewer.html"),
          "linkInfo.stayedOnViewer", str(render["linkInfo"]))

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
    check(states[0]["sidebarHeadings"] == 16, "smoke.first.sidebarHeadings",
          str(states[0]["sidebarHeadings"]))
    check(states[1]["title"] == "other.md", "smoke.second.title", states[1]["title"])
    check(states[1]["sidebarHeadings"] >= 2, "smoke.second.sidebarHeadings",
          str(states[1]["sidebarHeadings"]))
    check(states[0]["pageZoom"] == 1.25, "smoke.zoomPersisted", str(states[0]["pageZoom"]))

    # ---- Headerless chrome (single window, tab bar hidden) -----------------
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
    check(chrome.get("sidebarDragRegionHeight", -1) == safe_top,
          "chrome.sidebarDragRegionHeight",
          f"{chrome.get('sidebarDragRegionHeight')} != {safe_top}")
    check(chrome.get("sidebarDragHandlesAcceptMouse") is True,
          "chrome.sidebarDragHandlesAcceptMouse")
    check(chrome.get("contentDragRegionAcceptsMouse") is True,
          "chrome.contentDragRegionAcceptsMouse")
    check(chrome.get("sidebarHeaderTop", -1) >= safe_top, "chrome.sidebarHeaderTop",
          str(chrome.get("sidebarHeaderTop")))
    check(chrome.get("sidebarFirstRowTop", -1) >= safe_top + 34, "chrome.sidebarFirstRowTop",
          str(chrome.get("sidebarFirstRowTop")))
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
    jumps = extras.get("sidebarJumps", [])
    check(len(jumps) == states[0]["sidebarHeadings"], "smoke.sidebarJumpCount",
          f"{len(jumps)} != {states[0]['sidebarHeadings']}")
    check(all(jump.get("clicked") is True for jump in jumps),
          "smoke.sidebarAllClicked", str([j for j in jumps if j.get("clicked") is not True]))
    check(all(jump.get("visible") is True for jump in jumps),
          "smoke.sidebarAllVisible", str([j for j in jumps if j.get("visible") is not True]))

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
    check(extras["sidebarClick"] is True, "smoke.sidebarClick")
    check(extras["sidebarClickScrollY"] > 0, "smoke.sidebarClickScrollY",
          str(extras["sidebarClickScrollY"]))
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
    check(opened["tabBarVisible"] is True, "tabs.tabBarVisible")
    check(opened.get("nativeTabBarVisible") is False, "tabs.nativeTabBarHidden",
          str(opened.get("nativeTabBarVisible")))

    # Qdown draws its own tab strip in the document column. The sidebar keeps
    # the full window height (traffic lights on top), the strip starts exactly
    # at the split position and at the window's top edge, and all tabs share a
    # single row. The native titlebar tab bar must never come back.
    tabs_chrome = opened.get("chrome", {})
    check_document_tab_strip(tabs_chrome, "tabs.chrome", 2)
    check(tabs_chrome.get("fullSizeContentView") is True, "tabs.chrome.fullSizeContentView")
    check(tabs_chrome.get("titlebarAppearsTransparent") is True,
          "tabs.chrome.titlebarAppearsTransparent")
    check(tabs_chrome.get("titleVisibilityHidden") is True,
          "tabs.chrome.titleVisibilityHidden")
    check(tabs_chrome.get("titlebarSeparatorStyleNone") is True,
          "tabs.chrome.titlebarSeparatorStyleNone", str(tabs_chrome.get("titlebarSeparatorStyle")))
    check(tabs_chrome.get("titlebarHeight", -1) == 28,
          "tabs.chrome.titlebarHeight", str(tabs_chrome.get("titlebarHeight")))
    check(tabs_chrome.get("sidebarDragHandlesAcceptMouse") is True,
          "tabs.chrome.sidebarDragHandlesAcceptMouse")
    check(tabs_chrome.get("contentDragRegionAcceptsMouse") is True,
          "tabs.chrome.contentDragRegionAcceptsMouse")
    check(tabs_chrome.get("sidebarFirstRowTop", -1) >= 28 + 34,
          "tabs.chrome.sidebarFirstRowClearOfTabBar",
          str(tabs_chrome.get("sidebarFirstRowTop")))
    check(tabs_chrome.get("sidebarDragRegionHeight", -1) == 28,
          "tabs.chrome.sidebarDragRegionHeight",
          str(tabs_chrome.get("sidebarDragRegionHeight")))
    check(tabs_chrome.get("title") in opened.get("titles", []),
          "tabs.chrome.filenameStillAvailable", str(tabs_chrome.get("title")))

    per_tab = opened.get("perTab", [])
    check({entry["title"] for entry in per_tab} == {"test.md", "other.md"},
          "tabs.perTabTitles", str([entry.get("title") for entry in per_tab]))
    check(all(entry["tabTitle"] == entry["title"] for entry in per_tab),
          "tabs.tabTitleMatchesWindowTitle", str(per_tab))
    check(all(entry["sidebarHeadings"] > 0 for entry in per_tab),
          "tabs.perTabSidebars", str(per_tab))

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
    check(all(entry["sidebarHeadings"] > 0 for entry in local_link.get("perTab", [])),
          "tabs.localLink.perTabSidebars", str(local_link.get("perTab")))

    # ---- Real-screen tab bar capture ----------------------------------------
    check(tabs_screen.get("mode") == "tabs-screen", "tabsScreen.mode",
          str(tabs_screen.get("mode")))
    screen_chrome = tabs_screen.get("chrome", {})
    check(tabs_screen.get("windowNumber", -1) > 0, "tabsScreen.windowNumber",
          str(tabs_screen.get("windowNumber")))
    check(screen_chrome.get("tabBarVisible") is True, "tabsScreen.tabBarVisible")
    check(screen_chrome.get("sidebarWidth", -1) >= 180, "tabsScreen.sidebarWidth",
          str(screen_chrome.get("sidebarWidth")))
    check_document_tab_strip(screen_chrome, "tabsScreen.chrome", 3)

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
          "tabs.close.tabBarHidden",
          str(tab_close.get("tabBarVisibleAfterClose")))
    check(close_chrome.get("fullSizeContentView") is True,
          "tabs.close.fullSizeContentView")
    check(close_chrome.get("tabBarVisible") is False, "tabs.close.customTabBarHidden",
          str(close_chrome.get("tabBarVisible")))
    check(close_chrome.get("nativeTabBarVisible") is False,
          "tabs.close.nativeTabBarHidden", str(close_chrome.get("nativeTabBarVisible")))
    check(close_chrome.get("tabBarHeight") == 0, "tabs.close.tabBarHeight",
          str(close_chrome.get("tabBarHeight")))
    check(close_chrome.get("contentSafeAreaTop") == 28,
          "tabs.close.safeAreaTop", str(close_chrome.get("contentSafeAreaTop")))
    check(close_chrome.get("titlebarHeight") == 28,
          "tabs.close.titlebarHeight", str(close_chrome.get("titlebarHeight")))
    check(close_chrome.get("sidebarHeaderTop", -1) >= 28,
          "tabs.close.sidebarHeaderTop", str(close_chrome.get("sidebarHeaderTop")))
    check(close_chrome.get("webViewTop", -1) >= 28,
          "tabs.close.webViewTop", str(close_chrome.get("webViewTop")))
    check(close_chrome.get("sidebarDragRegionHeight", -1) == 28,
          "tabs.close.sidebarDragRegionHeight",
          str(close_chrome.get("sidebarDragRegionHeight")))

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
    check(live_tabs["tabBarVisible"] is True, "liveTabs.tabBarVisible")
    check(live_tabs.get("nativeTabBarVisible") is False, "liveTabs.nativeTabBarHidden",
          str(live_tabs.get("nativeTabBarVisible")))
    check_document_tab_strip(live_tabs.get("chrome", {}), "liveTabs.chrome", 2)
    live_per_tab = live_tabs.get("perTab", [])
    check({entry["title"] for entry in live_per_tab} == {"test.md", "other.md"},
          "liveTabs.perTabTitles", str([entry.get("title") for entry in live_per_tab]))
    check(all(entry["tabTitle"] == entry["title"] for entry in live_per_tab),
          "liveTabs.tabTitleMatchesWindowTitle", str(live_per_tab))
    check(all(entry["sidebarHeadings"] > 0 for entry in live_per_tab),
          "liveTabs.perTabSidebars", str(live_per_tab))

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
        "Contents/Resources/viewer.html",
        "Contents/Resources/viewer.css",
        "Contents/Resources/viewer.js",
    ):
        path = app / relative
        check(path.is_file() and path.stat().st_size > 0, f"bundle.{relative}")

    for png in ("01-top.png", "02-mermaid.png", "03-section.png", "04-sidebar.png",
                "05-headerless-window.png", "06-headerless-content.png",
                "07-headerless-tabs-window.png", "08-headerless-tabs-content.png",
                "09-real-tabs-window.png"):
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
