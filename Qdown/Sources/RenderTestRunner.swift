import AppKit
import Darwin
import WebKit

/// Headless verification harness. It is activated by `QDOWNTEST_MODE=render` or
/// `QDOWNTEST_MODE=smoke` (environment variable), and uses the exact production
/// WebView, scheme handler, viewer page, CSS, and JavaScript.
///
/// The harness deliberately reads all test settings from the environment so that
/// the app can be launched with **no command-line arguments**. macOS'
/// NSDocumentController interprets file-like argv entries as documents to open,
/// which can raise a blocking modal alert during unattended runs.
///
/// Command-line flags are still accepted for backwards compatibility, but the
/// automated verification script uses the environment-only form.
enum RenderTestRunner {

    private final class EventLog {
        private(set) var entries: [String] = []
        func append(_ value: String) { entries.append(value) }
    }

    private enum TestMode {
        case render
        case smoke
    }

    private static var mode: TestMode? {
        if let raw = ProcessInfo.processInfo.environment["QDOWNTEST_MODE"]?.lowercased() {
            if raw == "render" { return .render }
            if raw == "smoke" { return .smoke }
        }
        let arguments = CommandLine.arguments
        if arguments.contains("--smoke-test") { return .smoke }
        if arguments.contains(where: { $0 == "--render-test" || $0.hasPrefix("--render-test=") }) {
            return .render
        }
        return nil
    }

    static var isTestMode: Bool { mode != nil }

    private static var didStart = false

    static func run() {
        guard !didStart else { return }
        didStart = true
        let arguments = CommandLine.arguments
        switch mode {
        case .smoke:
            runSmokeTest(arguments: arguments)
        case .render:
            runRenderTest(arguments: arguments)
        case nil:
            return
        }
    }

    // MARK: - Render test

    private static func runRenderTest(arguments: [String]) {
        guard let markdownPath = setting("QDOWNTEST_MARKDOWN", flag: "--render-test", in: arguments),
              !markdownPath.isEmpty else {
            fail("usage: QDOWNTEST_MODE=render QDOWNTEST_MARKDOWN=<file.md> Qdown "
                 + "[also accepts --render-test <file.md>]")
        }

        let markdownURL = URL(fileURLWithPath: markdownPath).standardizedFileURL
        guard let data = try? Data(contentsOf: markdownURL) else {
            fail("cannot read \(markdownURL.path)")
        }
        guard let resourceDirectory = Bundle.main.resourceURL else {
            fail("missing app resources")
        }

        let markdown = TextDecoder.decode(data)
        let webView = MarkdownWebView(documentDirectory: markdownURL.deletingLastPathComponent(),
                                      resourceDirectory: resourceDirectory)
        let logs = EventLog()
        let linkEvents = EventLog()
        webView.onLog = { message in
            logs.append(message)
            FileHandle.standardError.write(("JSLOG: " + message + "\n").data(using: .utf8)!)
        }
        webView.onOpenLink = { linkEvents.append($0) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Qdown Render Test"
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        var rendered = false
        webView.onRenderDone = { _ in rendered = true }
        webView.render(markdown: markdown, baseDirectory: markdownURL.deletingLastPathComponent())

        Task { @MainActor in
            let finished = await waitUntil(timeout: 30) { rendered }
            if !finished {
                let detail = await evaluate(webView, "(document.readyState || 'nil') + ' / qdown=' + (typeof window.qdown) + ' / title=' + (document.title || 'nil')")
                FileHandle.standardError.write(("TIMEOUT detail: " + String(describing: detail) + "\n").data(using: .utf8)!)
                FileHandle.standardError.write(("TIMEOUT url: " + (webView.url?.absoluteString ?? "nil") + "\n").data(using: .utf8)!)
                logs.entries.forEach { FileHandle.standardError.write(("TIMEOUT LOG: " + $0 + "\n").data(using: .utf8)!) }
                fail("render test timed out")
            }
            await delay(0.4)
            await finishRenderTest(webView: webView,
                                   window: window,
                                   markdownURL: markdownURL,
                                   arguments: arguments,
                                   logs: logs,
                                   linkEvents: linkEvents)
        }
    }

    @MainActor
    private static func finishRenderTest(webView: MarkdownWebView,
                                         window: NSWindow,
                                         markdownURL: URL,
                                         arguments: [String],
                                         logs: EventLog,
                                         linkEvents: EventLog) async {
        let snapshotPath = setting("QDOWNTEST_SNAPSHOT", flag: "--snapshot", in: arguments)
        let diagramSnapshotPath = setting("QDOWNTEST_SNAPSHOT_DIAGRAM", flag: "--snapshot-diagram", in: arguments)
        let sectionSnapshotPath = setting("QDOWNTEST_SNAPSHOT_SECTION", flag: "--snapshot-section", in: arguments)
        let jsonPath = setting("QDOWNTEST_JSON", flag: "--json", in: arguments)
        let findTerm = setting("QDOWNTEST_FIND", flag: "--find", in: arguments) ?? "Markdown"
        let useFallbackFind = booleanSetting("QDOWNTEST_FALLBACK", flag: "--fallback", in: arguments)

        let initialSnapshot = await snapshot(of: webView, path: snapshotPath)
        let initial = await stats(from: webView)

        await scrollToHeading(containing: "Mermaid", in: webView)
        await delay(0.5)
        let diagram = await stats(from: webView)
        let diagramSnapshot = await snapshot(of: webView, path: diagramSnapshotPath)

        let linkInfo = await clickLinks(in: webView)
        let findResults = await runFindTests(on: webView, term: findTerm, fallback: useFallbackFind)
        let headingStats = await scrollToMiddleHeading(in: webView, initial: initial)
        let sectionSnapshot = await snapshot(of: webView, path: sectionSnapshotPath)

        let narrowStats = await resize(window: window, webView: webView, width: 520)
        let compactStats = await resize(window: window, webView: webView, width: 380)
        let wideStats = await resize(window: window, webView: webView, width: 1400)
        let restoredStats = await resize(window: window, webView: webView, width: 1100)
        let security = await securityProbe(in: webView)

        let result: [String: Any] = [
            "mode": "render",
            "file": markdownURL.path,
            "snapshot": initialSnapshot ?? "",
            "diagramSnapshot": diagramSnapshot ?? "",
            "sectionSnapshot": sectionSnapshot ?? "",
            "findTerm": findTerm,
            "findFallback": useFallbackFind,
            "requestedResources": webView.requestedResourcePaths,
            "logs": logs.entries,
            "linkEvents": linkEvents.entries,
            "linkInfo": linkInfo,
            "initial": initial,
            "diagram": diagram,
            "find": findResults,
            "headingScroll": headingStats,
            "narrow": narrowStats,
            "compact": compactStats,
            "wide": wideStats,
            "restored": restoredStats,
            "security": security,
        ]
        write(result: result, to: jsonPath, label: "QDOWNTEST")
        exit(0)
    }

    // MARK: - Smoke test

    private static func runSmokeTest(arguments: [String]) {
        var paths: [String] = []
        if let environmentFiles = ProcessInfo.processInfo.environment["QDOWNTEST_FILES"], !environmentFiles.isEmpty {
            paths = environmentFiles.split(separator: "\n").map(String.init)
        } else if let index = arguments.firstIndex(of: "--smoke-test") {
            var cursor = index + 1
            while cursor < arguments.count, !arguments[cursor].hasPrefix("--") {
                paths.append(arguments[cursor])
                cursor += 1
            }
        }
        guard !paths.isEmpty else {
            fail("usage: QDOWNTEST_MODE=smoke "
                 + "QDOWNTEST_FILES=$'file.md\\nother.md' Qdown "
                 + "[also accepts --smoke-test <file.md> ...]")
        }

        _ = NSDocumentController.shared

        // Seed a non-default zoom so a freshly created window proves that the
        // persisted UserDefaults value is applied on construction. With
        // QDOWNTEST_ZOOM_READ_ONLY=1 the harness does not write anything and
        // instead verifies the value left by a previous process.
        let readOnlyZoom = booleanSetting("QDOWNTEST_ZOOM_READ_ONLY",
                                          flag: "--smoke-zoom-read-only",
                                          in: arguments)
        var seedStore = ZoomStore()
        if !readOnlyZoom {
            seedStore.zoom = 1.25
        }

        var documents: [Document] = []
        var controllers: [DocumentWindowController] = []

        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard let data = try? Data(contentsOf: url) else {
                fail("cannot read \(url.path)")
            }
            let document = Document()
            document.fileURL = url
            do {
                try document.read(from: data, ofType: "net.daringfireball.markdown")
            } catch {
                fail("cannot decode \(url.path): \(error.localizedDescription)")
            }
            document.makeWindowControllers()
            guard let controller = document.windowControllers.first as? DocumentWindowController else {
                fail("no window controller for \(url.path)")
            }
            controller.showWindow(nil)
            documents.append(document)
            controllers.append(controller)
        }

        Task { @MainActor in
            let ready = await waitUntil(timeout: 15) {
                controllers.allSatisfy { ($0.debugState()["sidebarHeadings"] as? Int ?? 0) > 0 }
            }
            guard ready else { fail("native windows did not render in time") }

            var states = controllers.map { $0.debugState() }
            var extras: [String: Any] = [
                "documentCount": documents.count,
                "persistedZoomAtLaunch": seedStore.zoom,
                "zoomReadOnly": readOnlyZoom,
                "linkRouter": linkRouterChecks(base: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)),
                "textDecoder": textDecoderChecks(),
            ]

            if let first = controllers.first {
                if let sidebarSnapshot = setting("QDOWNTEST_SIDEBAR_SNAPSHOT",
                                                 flag: "--smoke-sidebar-snapshot",
                                                 in: arguments) {
                    extras["sidebarSnapshot"] = first.saveSidebarSnapshot(to: sidebarSnapshot) ?? ""
                }

                first.zoomIn(nil)
                extras["zoomIn"] = first.debugState()["pageZoom"] ?? 0
                first.actualSize(nil)
                extras["actualSize"] = first.debugState()["pageZoom"] ?? 0
                extras["persistedZoomAfterReset"] = ZoomStore().zoom

                let menuItem = NSMenuItem()
                menuItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                first.performFindPanelAction(menuItem)
                extras["findBarVisibleAfterFind"] = first.debugState()["findVisible"] ?? false

                first.findForTesting("Mermaid")
                await delay(0.7)
                let findState = first.debugState()
                extras["findCountText"] = findState["findCountText"] ?? ""
                extras["findQuery"] = findState["findQuery"] ?? ""

                let nextItem = NSMenuItem()
                nextItem.tag = Int(NSFindPanelAction.next.rawValue)
                first.performFindPanelAction(nextItem)
                await delay(0.5)
                extras["findCountTextAfterNext"] = first.debugState()["findCountText"] ?? ""

                let previousItem = NSMenuItem()
                previousItem.tag = Int(NSFindPanelAction.previous.rawValue)
                first.performFindPanelAction(previousItem)
                await delay(0.5)
                extras["findCountTextAfterPrevious"] = first.debugState()["findCountText"] ?? ""

                first.cancelOperation(nil)
                await delay(0.15)
                extras["findBarVisibleAfterEscape"] = first.debugState()["findVisible"] ?? false

                let clicked = first.clickSidebarHeadingForTesting(id: "qdown-heading-8")
                await delay(0.5)
                extras["sidebarClick"] = clicked
                extras["sidebarClickScrollY"] = await first.evaluateForTesting("window.scrollY") ?? -1

                // Click every sidebar heading and confirm the target heading is
                // brought into the visible viewport. This covers the "all
                // headings are jump targets" acceptance condition.
                var sidebarJumps: [[String: Any]] = []
                let headingTotal = (first.debugState()["sidebarHeadings"] as? Int) ?? 0
                let viewportHeight = Double(first.window?.contentView?.bounds.height ?? 0)
                for index in 0..<headingTotal {
                    let id = "qdown-heading-\(index)"
                    let jumpClicked = first.clickSidebarHeadingForTesting(id: id)
                    await delay(0.12)
                    let scrollY = await first.evaluateForTesting("window.scrollY") ?? -1
                    let script = "(function () { var e = document.getElementById('\(id)'); "
                        + "return e ? e.getBoundingClientRect().top : null; })()"
                    let headingTopValue = await first.evaluateForTesting(script)
                    let headingTop: Double
                    if let number = headingTopValue as? NSNumber {
                        headingTop = number.doubleValue
                    } else if let value = headingTopValue as? Double {
                        headingTop = value
                    } else {
                        headingTop = -9999
                    }
                    sidebarJumps.append([
                        "id": id,
                        "clicked": jumpClicked,
                        "scrollY": scrollY,
                        "headingTop": headingTop,
                        "visible": headingTop >= -8 && headingTop <= viewportHeight,
                    ])
                }
                extras["sidebarJumps"] = sidebarJumps
                extras["sidebarAllClicked"] = sidebarJumps.allSatisfy {
                    ($0["clicked"] as? Bool) == true
                }
                extras["sidebarAllVisible"] = sidebarJumps.allSatisfy {
                    ($0["visible"] as? Bool) == true
                }

                if booleanSetting("QDOWNTEST_LINK", flag: "--smoke-link", in: arguments) {
                    first.openLinkForTesting("Tests/fixtures/other.md")
                    await delay(1.8)
                    extras["localLinkWindowTitles"] = NSApp.windows
                        .filter { $0.isVisible }
                        .map { $0.title }
                        .sorted()
                }
            }

            states.append(extras)

            let result: [String: Any] = [
                "mode": "smoke",
                "files": paths,
                "windowTitles": controllers.compactMap { $0.window?.title },
                "visibleWindows": NSApp.windows.filter { $0.isVisible }.count,
                "windowDescriptions": NSApp.windows.map { window in
                    [
                        "title": window.title,
                        "class": String(describing: type(of: window)),
                        "visible": window.isVisible,
                        "frame": NSStringFromRect(window.frame),
                    ] as [String: Any]
                },
                "states": states,
            ]
            write(result: result, to: nil, label: "QDOWNSMOKE")
            exit(0)
        }
    }

    // MARK: - Test steps

    @MainActor
    private static func runFindTests(on webView: MarkdownWebView,
                                     term: String,
                                     fallback: Bool) async -> [String: Any] {
        if fallback {
            webView.setFindFallback(true)
            await delay(0.2)
        }

        let firstResult = await find(on: webView, term: term)
        let firstStats = await stats(from: webView)

        let nextResult = await findNext(on: webView, forward: true)
        let nextStats = await stats(from: webView)

        let zeroResult = await find(on: webView, term: "zzzz-qdown-no-such-term")
        let zeroStats = await stats(from: webView)
        webView.clearFind()

        return [
            "first": firstStats,
            "next": nextStats,
            "zero": zeroStats,
            "firstResult": ["count": firstResult.count, "current": firstResult.current],
            "nextResult": ["count": nextResult.count, "current": nextResult.current],
            "zeroResult": ["count": zeroResult.count, "current": zeroResult.current],
        ]
    }

    @MainActor
    private static func scrollToMiddleHeading(in webView: MarkdownWebView,
                                              initial: [String: Any]) async -> [String: Any] {
        let ids = (initial["headingIds"] as? [String]) ?? []
        guard ids.count > 2 else { return ["skipped": true] }
        let target = ids[ids.count / 2]
        _ = await evaluate(webView, "window.scrollTo(0, 0);")
        webView.scrollToHeading(id: target)
        await delay(0.45)
        var result = await stats(from: webView)
        result["targetHeading"] = target
        return result
    }

    @MainActor
    private static func scrollToHeading(containing text: String, in webView: MarkdownWebView) async {
        let quoted = "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let script = """
        (function () {
          var headings = Array.from(document.querySelectorAll('#content h1, #content h2, #content h3, #content h4, #content h5, #content h6'));
          var target = null;
          for (var i = 0; i < headings.length; i += 1) {
            if ((headings[i].textContent || '').trim().indexOf(\(quoted)) !== -1) { target = headings[i]; break; }
          }
          if (!target) { return false; }
          window.scrollTo(0, Math.max(0, window.scrollY + target.getBoundingClientRect().top - 18));
          return true;
        })()
        """
        _ = await evaluate(webView, script)
    }

    @MainActor
    private static func clickLinks(in webView: MarkdownWebView) async -> [String: Any] {
        let script = """
        (function () {
          var local = document.querySelector('#content a[href$=".md"]');
          var remote = document.querySelector('#content a[href^="http"]');
          if (local) { local.click(); }
          if (remote) { remote.click(); }
          return { href: location.href, hadLocal: !!local, hadRemote: !!remote };
        })()
        """
        let value = await evaluate(webView, script)
        await delay(0.3)
        return (value as? [String: Any]) ?? [:]
    }

    @MainActor
    private static func resize(window: NSWindow,
                               webView: MarkdownWebView,
                               width: CGFloat) async -> [String: Any] {
        window.setContentSize(NSSize(width: width, height: 860))
        window.contentView?.layoutSubtreeIfNeeded()
        await delay(0.65)
        return await stats(from: webView)
    }

    @MainActor
    private static func securityProbe(in webView: MarkdownWebView) async -> [String: Any] {
        let script = """
        JSON.stringify({
          pwned: typeof window.__qdownPwned !== 'undefined',
          scriptElements: document.querySelectorAll('#content script').length,
          iframeElements: document.querySelectorAll('#content iframe').length,
          inlineStyleElements: document.querySelectorAll('#content > style').length,
          svgStyleElements: document.querySelectorAll('#content svg style').length,
          javascriptHrefs: Array.from(document.querySelectorAll('#content a[href]')).filter(function (a) {
            return /^\\s*javascript:/i.test(a.getAttribute('href') || '');
          }).length,
          remoteImageSources: Array.from(document.querySelectorAll('#content img')).filter(function (img) {
            return /^https?:/i.test(img.getAttribute('src') || '');
          }).length,
          externalResources: (window.performance ? performance.getEntriesByType('resource').map(function (e) { return e.name; }).filter(function (n) { return !/^qdown:\\/\\//i.test(n); }) : [])
        })
        """
        let value = await evaluate(webView, script)
        guard let json = value as? String,
              let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return object
    }

    @MainActor
    private static func stats(from webView: MarkdownWebView) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            webView.debugJSON { json in
                guard let data = json.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    continuation.resume(returning: ["error": "invalid debug JSON", "raw": json])
                    return
                }
                continuation.resume(returning: object)
            }
        }
    }

    @MainActor
    private static func find(on webView: MarkdownWebView, term: String) async -> FindResult {
        await withCheckedContinuation { continuation in
            webView.find(term) { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    private static func findNext(on webView: MarkdownWebView, forward: Bool) async -> FindResult {
        await withCheckedContinuation { continuation in
            webView.findNext(forward: forward) { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    private static func evaluate(_ webView: MarkdownWebView, _ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }

    @MainActor
    private static func snapshot(of webView: MarkdownWebView, path: String?) async -> String? {
        guard let path else { return nil }
        return await withCheckedContinuation { continuation in
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            webView.takeSnapshot(with: configuration) { image, error in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    continuation.resume(returning: "snapshot failed: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try png.write(to: url)
                    continuation.resume(returning: url.path)
                } catch {
                    continuation.resume(returning: "snapshot write failed: \(error.localizedDescription)")
                }
            }
        }
    }

    @MainActor
    private static func waitUntil(timeout: Double, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return condition()
    }

    @MainActor
    private static func delay(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - Utilities

    private static func textDecoderChecks() -> [String: String] {
        let sample = "日本語テキスト"
        var bomUTF16 = Data([0xFF, 0xFE])
        bomUTF16.append(sample.data(using: .utf16LittleEndian) ?? Data())
        return [
            "utf8": TextDecoder.decode(sample.data(using: .utf8) ?? Data()),
            "shiftJIS": TextDecoder.decode(sample.data(using: .shiftJIS) ?? Data()),
            "eucJP": TextDecoder.decode(sample.data(using: .japaneseEUC) ?? Data()),
            "utf16LEWithBOM": TextDecoder.decode(bomUTF16),
        ]
    }

    private static func linkRouterChecks(base: URL) -> [String: String] {
        let cases = [
            "https://example.com/",
            "http://example.com/a",
            "mailto:someone@example.com",
            "Tests/fixtures/other.md",
            "../outside.md",
            "#mermaid",
            "javascript:alert(1)",
            "file:///tmp/example.md",
        ]
        var result: [String: String] = [:]
        for item in cases {
            switch LinkRouter.resolve(item, relativeTo: base) {
            case .external(let url):
                result[item] = "external:" + url.absoluteString
            case .localFile(let url):
                result[item] = "local:" + url.path
            case .unsupported:
                result[item] = "unsupported"
            }
        }
        return result
    }

    /// Reads a test setting from the environment first, then falls back to the
    /// legacy command-line flag. Environment-only launch is the supported path
    /// for unattended verification.
    private static func setting(_ environmentKey: String,
                                flag: String,
                                in arguments: [String]) -> String? {
        if let value = ProcessInfo.processInfo.environment[environmentKey], !value.isEmpty {
            return value
        }
        return value(of: flag, in: arguments)
    }

    private static func booleanSetting(_ environmentKey: String,
                                       flag: String,
                                       in arguments: [String]) -> Bool {
        if let raw = ProcessInfo.processInfo.environment[environmentKey] {
            return ["1", "true", "yes", "on"].contains(raw.lowercased())
        }
        return arguments.contains(flag)
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        if let inline = arguments.first(where: { $0.hasPrefix(flag + "=") }) {
            let value = String(inline.dropFirst(flag.count + 1))
            return value.isEmpty ? nil : value
        }
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        if value.hasPrefix("--") { return nil }
        return value
    }

    private static func write(result: [String: Any], to path: String?, label: String) {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            fail("cannot encode result: \(error.localizedDescription)")
        }
        if let path {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url)
            } catch {
                fail("cannot write \(url.path): \(error.localizedDescription)")
            }
        }
        if let text = String(data: data, encoding: .utf8) {
            print("\(label)_JSON:")
            print(text)
        }
        fflush(stdout)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(("QDOWNTEST_ERROR: " + message + "\n").data(using: .utf8)!)
        exit(2)
    }
}
