#!/usr/bin/env python3
"""Assert Qdown's automated verification results."""
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
    link_titles = smoke_link["states"][-1].get("localLinkWindowTitles", [])
    check("other.md" in link_titles, "smokeLink.otherWindow", str(link_titles))
    check("test.md" in link_titles, "smokeLink.originalWindow", str(link_titles))

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

    for png in ("01-top.png", "02-mermaid.png", "03-section.png", "04-sidebar.png"):
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
