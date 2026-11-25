#!/usr/bin/env python3
"""Assert Qdown's automated verification results.

The suite covers Markdown rendering, the shared theme, find, the floating
outline (method A), AppKit's native window tabs, and the headerless window.
"""
import hashlib
import json
import plistlib
import struct
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
    live_reload = json.loads((out / "live-reload.json").read_text())
    tabs = json.loads((out / "tabs.json").read_text())
    tabs_screen = json.loads((out / "tabs-screen.json").read_text())
    live_tabs = json.loads((out / "live-tabs.json").read_text())
    outline_screen = json.loads((out / "outline-screen.json").read_text())
    single_screen = json.loads((out / "single-screen.json").read_text())
    session_save = json.loads((out / "session-save.json").read_text())
    session_restore = json.loads((out / "session-restore.json").read_text())
    session_arguments = json.loads((out / "session-arguments.json").read_text())
    production_restore = json.loads((out / "production-restore.json").read_text())

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
    # The bars are anchored to the window's right edge, not the text column.
    # outlineRightGap is the measured on-screen distance from that edge.
    check(abs(initial_outline.get("outlineRightGap", 0) - 12.0) <= 1.5,
          "render.initial.outlineAtWindowRightMargin",
          f"outlineRightGap={initial_outline.get('outlineRightGap')}, "
          f"textRightGap={initial_outline.get('textRightGap')}")
    bar_gaps = initial_outline.get("barRightGaps", [])
    check(bool(bar_gaps)
          and all(abs(gap - initial_outline.get("outlineRightGap", 0)) <= 1.0
                  for gap in bar_gaps),
          "render.initial.barsAtOutlineRightEdge", str(bar_gaps[:4]))
    check(initial_outline.get("barClearOfText") is True,
          "render.initial.barsClearOfText",
          f"outlineRightGap={initial_outline.get('outlineRightGap')}, "
          f"barLeftGap={initial_outline.get('barLeftGap')}, "
          f"textRightGap={initial_outline.get('textRightGap')}")
    check(abs(initial_outline.get("outlineHeight", 0)
              - initial_outline.get("viewportHeight", 0)
              * initial_outline.get("pageZoom", 1)) <= 2.0,
          "render.initial.outlineFullHeight",
          f"{initial_outline.get('outlineHeight')} vs "
          f"{initial_outline.get('viewportHeight')}*{initial_outline.get('pageZoom')}")
    check(initial_outline.get("compact") is False,
          "render.initial.outlineNotCompact", str(initial_outline.get("compact")))
    # The invisible hover target is much wider than the 24pt visible column and
    # the panel overlaps it, so there is no dead zone between the two.
    check(initial_outline.get("outlineHitWidth", 0) >= 40.0,
          "render.initial.outlineHitWidth", str(initial_outline.get("outlineHitWidth")))
    check(initial_outline.get("outlineHitWidth", 0) <= 48.0,
          "render.initial.outlineHitWidthNotTooWide",
          str(initial_outline.get("outlineHitWidth")))
    check(abs(initial_outline.get("outlineHitRightGap", 0)) <= 1.5,
          "render.initial.outlineHitReachesWindowEdge",
          str(initial_outline.get("outlineHitRightGap")))
    check(initial_outline.get("barsInsideHit") is True,
          "render.initial.barsInsideHit",
          f"outlineRightGap={initial_outline.get('outlineRightGap')}, "
          f"barLeftGap={initial_outline.get('barLeftGap')}, "
          f"hitLeftGap={initial_outline.get('outlineHitLeftGap')}")
    check(initial_outline.get("panelOverlapsHit") is True,
          "render.initial.outlinePanelOverlapsHit",
          f"panelRight={initial_outline.get('panelRight')}, "
          f"hitLeft={initial_outline.get('outlineHitLeft')}")
    check(initial_outline.get("closeDelayMs") == 400,
          "render.initial.outlineCloseDelay", str(initial_outline.get("closeDelayMs")))

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

    # Narrow windows use the 6-8pt bar variant. The bars still hug the window
    # edge, and their margin is clamped only as far as needed to clear the text.
    narrow_outline = render["narrow"].get("outline", {})
    check(narrow_outline.get("compact") is True, "outline.narrow.compact",
          str(narrow_outline.get("compact")))
    check(max(narrow_outline.get("rectEffectiveBarWidths") or [99]) <= 8.5,
          "outline.narrow.barWidth", str(narrow_outline.get("rectEffectiveBarWidths")))
    check(min(narrow_outline.get("barRightGaps") or [0]) >= 0,
          "outline.narrow.barsInsideWindow", str(narrow_outline.get("barRightGaps")))
    check(narrow_outline.get("outlineHitWidth", 0) >= 40.0,
          "outline.narrow.hitWidth", str(narrow_outline.get("outlineHitWidth")))
    check(narrow_outline.get("panelOverlapsHit") is True,
          "outline.narrow.panelOverlapsHit")
    check(narrow_outline.get("barsInsideHit") is True,
          "outline.narrow.barsInsideHit")

    # Normal widths: bars sit at the 12pt window margin. Narrow/compact windows
    # use the 6-8pt bars and clamp the margin to 8pt so the bars stay clear of
    # the text column (the theme's 16pt side padding is the limiting gap).
    for name, expected_gap in (("narrow", 8.0), ("wide", 12.0)):
        section_outline = render[name].get("outline", {})
        gap = section_outline.get("outlineRightGap")
        check(gap is not None and abs(gap - expected_gap) <= 1.5,
              f"outline.{name}.windowRightMargin", str(gap))
        check(section_outline.get("barClearOfText") is True,
              f"outline.{name}.barsClearOfText",
              f"outlineRightGap={gap}, "
              f"textRightGap={section_outline.get('textRightGap')}")
    compact_outline = render["compact"].get("outline", {})
    compact_gap = compact_outline.get("outlineRightGap")
    check(compact_outline.get("compact") is True, "outline.compact.compact")
    check(compact_gap is not None and abs(compact_gap - 8.0) <= 1.5,
          "outline.compact.windowRightMargin", str(compact_gap))
    check(compact_outline.get("barClearOfText") is True,
          "outline.compact.barsClearOfText",
          f"outlineRightGap={compact_gap}, "
          f"textRightGap={compact_outline.get('textRightGap')}")
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

    # Hover intent over the wider strip: opening, 400ms close grace, and
    # cancellation when the pointer re-enters.
    hover = render.get("outlineHover", {})
    check(hover.get("available") is True, "outline.hover.available")
    check(hover.get("opened") is True, "outline.hover.opensOnStrip",
          str(hover.get("opened")))
    check(hover.get("panelHold") is True, "outline.hover.mergedPanelRegion",
          str(hover.get("panelHold")))
    check(hover.get("graceOpen") is True, "outline.hover.staysOpenInGrace",
          str(hover.get("graceOpen")))
    check(hover.get("reentryOpened") is True, "outline.hover.reentryOpens",
          str(hover.get("reentryOpened")))
    check(hover.get("openAfterReentry") is True,
          "outline.hover.reentryCancelsClose", str(hover.get("openAfterReentry")))
    check(hover.get("closedAfterDelay") is False, "outline.hover.closesAfterDelay",
          str(hover.get("closedAfterDelay")))
    check(hover.get("edgeOpened") is True, "outline.hover.opensAtWindowEdge",
          str(hover.get("edgeOpened")))

    # ---- Floating outline (zoom invariance) --------------------------------
    zooms = render["outlineZooms"]
    check(set(zooms.keys()) == {"0.50", "1.00", "1.25", "2.50"},
          "outline.zoom.cases", str(sorted(zooms.keys())))
    baseline = zooms.get("1.00", {}).get("outline", {}).get("rectEffectiveBarWidths", [])
    check(bool(baseline), "outline.zoom.baseline")
    baseline_panel_width = zooms.get("1.00", {}).get(
        "outline", {}).get("panelEffectiveWidth", 0)
    check(baseline_panel_width > 0, "outline.zoom.panelBaseline",
          str(baseline_panel_width))
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
        check(abs(outline.get("outlineRightGap", 0) - 12.0) <= 1.5,
              f"outline.zoom.{key}.windowRightMarginConstant",
              str(outline.get("outlineRightGap")))
        check(abs(outline.get("panelEffectiveWidth", 0) - baseline_panel_width) <= 1.0,
              f"outline.zoom.{key}.panelWidthConstant",
              str(outline.get("panelEffectiveWidth")))
        check(abs(outline.get("panelRightGap", 0) - 32.0) <= 1.5,
              f"outline.zoom.{key}.panelRightGapConstant",
              str(outline.get("panelRightGap")))
        check(outline.get("barClearOfText") is True,
              f"outline.zoom.{key}.barsClearOfText",
              f"outlineRightGap={outline.get('outlineRightGap')}, "
              f"textRightGap={outline.get('textRightGap')}")
        check(entry.get("layout", {}).get("overflowX") is False,
              f"outline.zoom.{key}.noOverflow")
        check(abs(outline.get("outlineHitWidth", 0) - 44.0) <= 1.5,
              f"outline.zoom.{key}.hitWidthConstant",
              str(outline.get("outlineHitWidth")))
        check(outline.get("barsInsideHit") is True,
              f"outline.zoom.{key}.barsInsideHit")
        check(outline.get("panelOverlapsHit") is True,
              f"outline.zoom.{key}.panelOverlapsHit")

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

    # ---- Live reload --------------------------------------------------------
    check(live_reload.get("mode") == "live-reload", "liveReload.mode",
          str(live_reload.get("mode")))
    initial_lr = live_reload["initial"]
    check(initial_lr.get("markerFound") is True, "liveReload.initial.marker")
    check(initial_lr.get("renderCount", 0) >= 1, "liveReload.initial.rendered",
          str(initial_lr.get("renderCount")))
    check(initial_lr.get("headingCount", 0) >= 40, "liveReload.initial.headingCount",
          str(initial_lr.get("headingCount")))
    check(initial_lr.get("scrollY", 0) > 0, "liveReload.initial.scrollable",
          str(initial_lr.get("scrollY")))

    in_place = live_reload["inPlace"]
    check(in_place.get("updated") is True, "liveReload.inPlace.updated")
    check(in_place.get("markerFound") is True, "liveReload.inPlace.domUpdated")
    check(in_place.get("renderCountIncreased") is True,
          "liveReload.inPlace.rerendered", str(in_place.get("renderCount")))
    check(in_place.get("scrollPreserved") is True, "liveReload.inPlace.scrollPreserved",
          f"{in_place.get('scrollBefore')} -> {in_place.get('scrollY')}")
    check(in_place.get("zoomPreserved") is True, "liveReload.inPlace.zoomPreserved",
          str(in_place.get("pageZoom")))

    atomic = live_reload["atomic"]
    check(atomic.get("updated") is True, "liveReload.atomic.updated")
    check(atomic.get("markerFound") is True, "liveReload.atomic.domUpdated")
    check(atomic.get("renderCountIncreased") is True,
          "liveReload.atomic.rerendered", str(atomic.get("renderCount")))
    check(atomic.get("scrollPreserved") is True, "liveReload.atomic.scrollPreserved",
          f"{atomic.get('scrollBefore')} -> {atomic.get('scrollY')}")
    check(atomic.get("zoomPreserved") is True, "liveReload.atomic.zoomPreserved",
          str(atomic.get("pageZoom")))

    mtime_only = live_reload["mtimeOnly"]
    check(mtime_only.get("unchanged") is True, "liveReload.mtimeOnly.noRerender",
          f"{mtime_only.get('renderCountBefore')} -> {mtime_only.get('renderCount')}")
    check(mtime_only.get("markerStillAtomic") is True,
          "liveReload.mtimeOnly.contentUnchanged")

    deleted = live_reload["deleted"]
    check(deleted.get("keptLastContent") is True, "liveReload.deleted.keepsLastContent")
    check(deleted.get("renderCountUnchanged") is True,
          "liveReload.deleted.noRerender", str(deleted.get("renderCount")))

    recreated = live_reload["recreated"]
    check(recreated.get("updated") is True, "liveReload.recreated.updated")
    check(recreated.get("markerFound") is True, "liveReload.recreated.domUpdated")
    check(recreated.get("renderCountIncreased") is True,
          "liveReload.recreated.rerendered", str(recreated.get("renderCount")))

    focus = live_reload["focus"]
    check(focus.get("preserved") is True, "liveReload.focus.preserved", str(focus))
    check(live_reload.get("logs") == [], "liveReload.logs", str(live_reload.get("logs")))

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
    # Regression: the drag handle must be found through the real content-view
    # hit-test path, at the top edge, spanning the titlebar safe area. Testing
    # the view's own bounds had previously hidden a coordinate-space bug.
    check(chrome.get("contentDragRegionHitIsDragHandle") is True,
          "chrome.contentDragRegionHitIsDragHandle")
    check(chrome.get("contentDragRegionTopInWindow", -1) == 0,
          "chrome.contentDragRegionTopInWindow",
          str(chrome.get("contentDragRegionTopInWindow")))
    check(chrome.get("contentDragRegionHeight", -1) == safe_top,
          "chrome.contentDragRegionHeight",
          str(chrome.get("contentDragRegionHeight")))
    check(chrome.get("contentDragRegionHandoff") == "screenDelta",
          "chrome.contentDragRegionHandoff", str(chrome.get("contentDragRegionHandoff")))
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
    check(tabs_chrome.get("contentDragRegionHitIsDragHandle") is True,
          "tabs.chrome.contentDragRegionHitIsDragHandle")
    check(tabs_chrome.get("contentDragRegionTopInWindow", -1) == 0,
          "tabs.chrome.contentDragRegionTopInWindow",
          str(tabs_chrome.get("contentDragRegionTopInWindow")))
    check(tabs_chrome.get("contentDragRegionHeight", -1) == tab_safe_top,
          "tabs.chrome.contentDragRegionHeight",
          str(tabs_chrome.get("contentDragRegionHeight")))
    check(tabs_chrome.get("contentDragRegionHandoff") == "screenDelta",
          "tabs.chrome.contentDragRegionHandoff",
          str(tabs_chrome.get("contentDragRegionHandoff")))
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
    check(close_chrome.get("contentDragRegionHitIsDragHandle") is True,
          "tabs.close.contentDragRegionHitIsDragHandle")
    check(close_chrome.get("contentDragRegionTopInWindow", -1) == 0,
          "tabs.close.contentDragRegionTopInWindow",
          str(close_chrome.get("contentDragRegionTopInWindow")))
    check(close_chrome.get("contentDragRegionHeight", -1) == 28,
          "tabs.close.contentDragRegionHeight",
          str(close_chrome.get("contentDragRegionHeight")))

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
        capture_gap = capture_outline.get("outlineRightGap")
        check(capture_gap is not None and abs(capture_gap - 12.0) <= 1.5,
              f"{label}.outlineAtWindowRightMargin", str(capture_gap))
        check(capture_outline.get("barClearOfText") is True,
              f"{label}.barsClearOfText",
              f"outlineRightGap={capture_gap}, "
              f"textRightGap={capture_outline.get('textRightGap')}")
        check(capture_outline.get("barsInsideHit") is True,
              f"{label}.barsInsideHit")
    check_outline_headings(load_outline(outline_screen.get("outline")),
                           "outlineScreen.expanded")
    screenshot_outline = load_outline(outline_screen.get("outline"))
    check(screenshot_outline.get("expanded") is True, "outlineScreen.panelExpanded")
    check(screenshot_outline.get("panelVisible") is True, "outlineScreen.panelVisible")
    check(screenshot_outline.get("panelOverlapsHit") is True,
          "outlineScreen.panelOverlapsHit",
          f"panelRightGap={screenshot_outline.get('panelRightGap')}")

    # ---- Tab session restore -------------------------------------------------
    check(session_save.get("mode") == "session-save", "sessionSave.mode",
          str(session_save.get("mode")))
    check(session_save.get("terminatingNormally") is True, "sessionSave.normalQuit")
    check(session_save.get("requestedActiveIndex") == 2, "sessionSave.requestedActive")
    expected_open = ["a.md", "b.md", "a.md", "c.md", "temp.md"]
    check(session_save["afterOpen"]["titles"] == expected_open,
          "sessionSave.tabOrderAfterOpen", str(session_save["afterOpen"]["titles"]))
    check([Path(path).name for path in session_save["afterOpen"]["paths"]] == expected_open,
          "sessionSave.savedPathsAfterOpen",
          str(session_save["afterOpen"]["paths"]))
    check(session_save["afterSwitch"]["activeIndex"] == 2,
          "sessionSave.switchSaved", str(session_save["afterSwitch"]["activeIndex"]))
    check(session_save["afterSwitch"]["selectedTitle"] == "a.md",
          "sessionSave.switchTarget", str(session_save["afterSwitch"]["selectedTitle"]))
    check(session_save["afterClose"]["titles"] == ["a.md", "b.md", "a.md", "c.md"],
          "sessionSave.closeSaved", str(session_save["afterClose"]["titles"]))
    check([Path(path).name for path in session_save["afterClose"]["paths"]]
          == ["a.md", "b.md", "a.md", "c.md"],
          "sessionSave.closePaths", str(session_save["afterClose"]["paths"]))
    check(session_save["afterClose"]["activeIndex"] == 2,
          "sessionSave.activeAfterClose", str(session_save["afterClose"]["activeIndex"]))
    check(session_save["afterClose"]["selectedTitle"] == "a.md",
          "sessionSave.selectedAfterClose",
          str(session_save["afterClose"]["selectedTitle"]))
    check(session_save["afterSuspendedSwitch"]["activeIndex"] == 2,
          "sessionSave.suspendedSaveDidNotRun",
          str(session_save["afterSuspendedSwitch"]["activeIndex"]))
    check(session_save.get("terminationActiveIndex") == 1,
          "sessionSave.terminationTarget",
          str(session_save.get("terminationActiveIndex")))

    check(session_restore.get("mode") == "session-restore", "sessionRestore.mode",
          str(session_restore.get("mode")))
    check(session_restore.get("documentsAtLaunch") == 0,
          "sessionRestore.noAppKitReopen",
          f"{session_restore.get('documentsAtLaunch')}: "
          f"{session_restore.get('launchDocumentURLs')}")
    check([Path(path).name for path in session_restore.get("savedPaths", [])]
          == ["a.md", "b.md", "a.md", "c.md"],
          "sessionRestore.savedBeforeDelete", str(session_restore.get("savedPaths")))
    check(session_restore.get("savedActiveIndex") == 1,
          "sessionRestore.terminationSaved", str(session_restore.get("savedActiveIndex")))
    check(session_restore.get("outcome") == "restored(3)",
          "sessionRestore.outcome", str(session_restore.get("outcome")))
    check(session_restore.get("tabCount") == 3, "sessionRestore.tabCount",
          str(session_restore.get("tabCount")))
    check(session_restore.get("documentWindowCount") == 1,
          "sessionRestore.singleWindow", str(session_restore.get("documentWindowCount")))
    check(session_restore.get("renderedTabs") == 3, "sessionRestore.renderedTabs",
          str(session_restore.get("renderedTabs")))
    check(session_restore.get("titles") == ["a.md", "b.md", "a.md"],
          "sessionRestore.order", str(session_restore.get("titles")))
    check([Path(path).name for path in session_restore.get("restoredPaths", [])]
          == ["a.md", "b.md", "a.md"],
          "sessionRestore.duplicatesKept", str(session_restore.get("restoredPaths")))
    check(session_restore.get("activeIndex") == 1, "sessionRestore.activeIndex",
          str(session_restore.get("activeIndex")))
    check(session_restore.get("activeTitle") == "b.md", "sessionRestore.activeTitle",
          str(session_restore.get("activeTitle")))
    check([Path(path).name for path in session_restore.get("sessionAfterRestore", [])]
          == ["a.md", "b.md", "a.md"],
          "sessionRestore.missingFileDropped",
          str(session_restore.get("sessionAfterRestore")))

    check(session_arguments.get("mode") == "session-arguments",
          "sessionArguments.mode", str(session_arguments.get("mode")))
    check([Path(path).name for path in session_arguments.get("savedPathsBefore", [])]
          == ["a.md", "b.md", "a.md"],
          "sessionArguments.oldSessionExists",
          str(session_arguments.get("savedPathsBefore")))
    check(session_arguments.get("skipOutcome") == "skippedLaunchArguments",
          "sessionArguments.fileArgumentWins",
          str(session_arguments.get("skipOutcome")))
    check(session_arguments.get("documentsAfterSkip") == 0,
          "sessionArguments.noRestoreOnArgument",
          str(session_arguments.get("documentsAfterSkip")))
    check(session_arguments.get("tabsAfterSkip") == 0,
          "sessionArguments.noTabsOnArgument",
          str(session_arguments.get("tabsAfterSkip")))
    check(session_arguments.get("argumentTitle") == "a.md",
          "sessionArguments.argumentOpened", str(session_arguments.get("argumentTitle")))
    check(session_arguments.get("argumentTabCount") == 1,
          "sessionArguments.singleArgumentTab",
          str(session_arguments.get("argumentTabCount")))
    check(session_arguments.get("emptyOutcome") == "noSavedSession",
          "sessionArguments.emptySession", str(session_arguments.get("emptyOutcome")))
    check(session_arguments.get("documentsAfterEmpty") == 1,
          "sessionArguments.emptyOpensNothing",
          str(session_arguments.get("documentsAfterEmpty")))
    check(session_arguments.get("tabsAfterEmpty") == 1,
          "sessionArguments.emptyTabsUnchanged",
          str(session_arguments.get("tabsAfterEmpty")))

    check(production_restore.get("outcome") == "restored(count: 3)",
          "productionRestore.outcome", str(production_restore.get("outcome")))
    check(production_restore.get("tabCount") == 3, "productionRestore.tabCount",
          str(production_restore.get("tabCount")))
    check(production_restore.get("titles") == ["a.md", "b.md", "a.md"],
          "productionRestore.order", str(production_restore.get("titles")))
    check([Path(path).name for path in production_restore.get("paths", [])]
          == ["a.md", "b.md", "a.md"],
          "productionRestore.paths", str(production_restore.get("paths")))
    check(production_restore.get("activeTitle") == "b.md",
          "productionRestore.activeTitle", str(production_restore.get("activeTitle")))

    # ---- Artifacts, CSS, Info.plist ----------------------------------------
    expected_css_hash = "5e33b8e7a578e0b5f93467ff7882c4314d1fcad9d3863ea0656151f0300477b6"
    source_css = (root / "Qdown" / "Resources" / "quiet-light.css").read_bytes()
    built_css = (app / "Contents" / "Resources" / "quiet-light.css").read_bytes()
    check(hashlib.sha256(source_css).hexdigest() == expected_css_hash, "css.sourceHash")
    check(hashlib.sha256(built_css).hexdigest() == expected_css_hash, "css.builtHash")
    check(source_css == built_css, "css.source==built")

    info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    check(info.get("CFBundleIconFile") in ("AppIcon", "AppIcon.icns"),
          "icon.infoPlistReference", str(info.get("CFBundleIconFile")))
    source_icon = (root / "Qdown" / "Resources" / "AppIcon.icns").read_bytes()
    built_icon_path = app / "Contents" / "Resources" / "AppIcon.icns"
    built_icon = built_icon_path.read_bytes() if built_icon_path.is_file() else b""
    check(built_icon[:4] == b"icns", "icon.icnsMagic", built_icon[:4].hex())
    check(len(built_icon) > 100_000, "icon.icnsSize", str(len(built_icon)))
    check(source_icon == built_icon, "icon.source==built")

    def png_size(path):
        data = path.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            return None
        return struct.unpack(">II", data[16:24])

    iconset = out / "AppIcon.iconset"
    required_icons = {
        "icon_16x16.png": (16, 16),
        "icon_16x16@2x.png": (32, 32),
        "icon_32x32.png": (32, 32),
        "icon_32x32@2x.png": (64, 64),
        "icon_128x128.png": (128, 128),
        "icon_128x128@2x.png": (256, 256),
        "icon_256x256.png": (256, 256),
        "icon_256x256@2x.png": (512, 512),
        "icon_512x512.png": (512, 512),
        "icon_512x512@2x.png": (1024, 1024),
    }
    for name, dimensions in required_icons.items():
        path = iconset / name
        check(path.is_file() and path.stat().st_size > 100,
              f"icon.iconset.{name}.exists")
        check(path.is_file() and png_size(path) == dimensions,
              f"icon.iconset.{name}.dimensions",
              str(png_size(path) if path.is_file() else None))

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
