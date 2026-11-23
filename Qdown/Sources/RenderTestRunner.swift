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
        case tabs
        case liveTabs
        case liveReload
        case window
    }

    private static var mode: TestMode? {
        if let raw = ProcessInfo.processInfo.environment["QDOWNTEST_MODE"]?.lowercased() {
            if raw == "render" { return .render }
            if raw == "smoke" { return .smoke }
            if raw == "tabs" { return .tabs }
            if raw == "live-tabs" { return .liveTabs }
            if raw == "live-reload" || raw == "live" { return .liveReload }
            if raw == "window" { return .window }
        }
        let arguments = CommandLine.arguments
        if arguments.contains("--smoke-test") { return .smoke }
        if arguments.contains("--tabs-test") { return .tabs }
        if arguments.contains("--live-tabs-test") { return .liveTabs }
        if arguments.contains("--live-reload-test") { return .liveReload }
        if arguments.contains(where: { $0 == "--render-test" || $0.hasPrefix("--render-test=") }) {
            return .render
        }
        return nil
    }

    static var isTestMode: Bool { mode != nil }

    /// The live-tabs harness verifies the real `application(_:open:)` path, so
    /// it must accept LaunchServices open events while every other harness mode
    /// ignores them.
    static var acceptsOpenEvents: Bool { mode == .liveTabs }

    private static var didStart = false

    @MainActor
    static func run() {
        guard !didStart else { return }
        didStart = true

        // The harness builds windows directly, so keep AppKit from grouping
        // them implicitly. Tab behaviour is exercised explicitly through
        // DocumentOpenCoordinator and should not depend on the machine's
        // "Prefer tabs when opening documents" preference.
        NSWindow.allowsAutomaticWindowTabbing = false

        // The legacy smoke test deliberately constructs two standalone windows
        // to keep covering the multi-window code path. Production keeps
        // automatic tab attachment enabled.
        if case .smoke = mode {
            DocumentOpenCoordinator.automaticallyTabsNewDocuments = false
        }

        let arguments = CommandLine.arguments
        switch mode {
        case .smoke:
            runSmokeTest(arguments: arguments)
        case .render:
            runRenderTest(arguments: arguments)
        case .tabs:
            runTabTest(arguments: arguments)
        case .liveTabs:
            runLiveTabsTest(arguments: arguments)
        case .liveReload:
            runLiveReloadTest(arguments: arguments)
        case .window:
            runWindowTest(arguments: arguments)
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

        // Floating outline: the active bar must follow the heading the harness
        // just jumped to, a bar click must smooth-scroll to its heading, and
        // the hover/test panel must expand without reflowing the document.
        let outlineAfterScroll = await stats(from: webView)
        let outlineClicked = await evaluate(webView,
            "(function(){var b=document.querySelectorAll('#qdown-outline .qdown-outline-bar');"
            + "if(!b.length){return -1;}var i=3;b[i].click();return i;})()")
        await delay(1.3)
        var outlineClickStats = await stats(from: webView)
        outlineClickStats["clickedIndex"] = outlineClicked ?? -1
        outlineClickStats["scrollY"] = await evaluate(webView, "window.scrollY") ?? -1
        outlineClickStats["targetHeadingTop"] = await evaluate(webView,
            "(function(){var h=document.getElementById('qdown-heading-3');"
            + "return h?h.getBoundingClientRect().top:null;})()") ?? -1
        _ = await evaluate(webView, "window.qdown.setOutlineExpanded(true);")
        await delay(0.3)
        let outlineExpandedStats = await stats(from: webView)
        _ = await evaluate(webView, "window.qdown.setOutlineExpanded(false);")

        // Hover intent: the invisible bar strip is wider than the visible bars
        // and the expanded panel overlaps it. Leaving the merged hover region
        // keeps the panel open for a 400ms grace period; re-entry cancels the
        // pending close. Synthetic mouse events exercise the real listeners.
        let outlineHoverEnter = await evaluate(webView, """
            (function(){
              var o=document.getElementById('qdown-outline');
              var b=o.querySelector('.qdown-outline-bar');
              if(!b){return {available:false};}
              var r=b.getBoundingClientRect();
              window.dispatchEvent(new MouseEvent('mousemove',
                {bubbles:true,clientX:r.right-2,clientY:r.top+r.height/2}));
              return {available:true,expanded:o.classList.contains('qdown-outline-open')};
            })()
            """) as? [String: Any] ?? [:]
        // Moving from the strip into the expanded panel keeps the merged
        // region hovered (the panel overlaps the strip).
        let outlineHoverPanel = await evaluate(webView, """
            (function(){
              var o=document.getElementById('qdown-outline');
              var p=o.querySelector('.qdown-outline-panel');
              if(!p){return false;}
              var r=p.getBoundingClientRect();
              window.dispatchEvent(new MouseEvent('mousemove',
                {bubbles:true,clientX:r.left+r.width/2,clientY:r.top+r.height/2}));
              return o.classList.contains('qdown-outline-open');
            })()
            """) as? Bool ?? false
        _ = await evaluate(webView, """
            window.dispatchEvent(new MouseEvent('mousemove',
              {bubbles:true,clientX:5,clientY:5}));
            """)
        await delay(0.12)
        let outlineHoverGrace = await evaluate(webView,
            "document.getElementById('qdown-outline').classList.contains('qdown-outline-open')")
            as? Bool ?? false
        let outlineHoverReentry = await evaluate(webView, """
            (function(){
              var o=document.getElementById('qdown-outline');
              var b=o.querySelector('.qdown-outline-bar');
              if(!b){return false;}
              var r=b.getBoundingClientRect();
              window.dispatchEvent(new MouseEvent('mousemove',
                {bubbles:true,clientX:r.right-2,clientY:r.top+r.height/2}));
              return o.classList.contains('qdown-outline-open');
            })()
            """) as? Bool ?? false
        await delay(0.7)
        let outlineHoverAfterReentry = await evaluate(webView,
            "document.getElementById('qdown-outline').classList.contains('qdown-outline-open')")
            as? Bool ?? false
        _ = await evaluate(webView, """
            window.dispatchEvent(new MouseEvent('mousemove',
              {bubbles:true,clientX:5,clientY:5}));
            """)
        await delay(1.6)
        let outlineHoverClosed = await evaluate(webView,
            "document.getElementById('qdown-outline').classList.contains('qdown-outline-open')")
            as? Bool ?? true
        let outlineHover: [String: Any] = [
            "available": outlineHoverEnter["available"] ?? false,
            "opened": outlineHoverEnter["expanded"] ?? false,
            "panelHold": outlineHoverPanel,
            "graceOpen": outlineHoverGrace,
            "reentryOpened": outlineHoverReentry,
            "openAfterReentry": outlineHoverAfterReentry,
            "closedAfterDelay": outlineHoverClosed,
        ]

        let narrowStats = await resize(window: window, webView: webView, width: 520)
        let compactStats = await resize(window: window, webView: webView, width: 380)
        let wideStats = await resize(window: window, webView: webView, width: 1400)
        let restoredStats = await resize(window: window, webView: webView, width: 1100)

        // The outline must keep a constant on-screen bar width at every page
        // zoom. WKWebView.pageZoom scales the page, so the page counter-scales
        // the outline by 1/zoom.
        var outlineZooms: [String: Any] = [:]
        for zoom in [0.5, 1.0, 1.25, 2.5] {
            webView.applyPageZoom(zoom)
            _ = await evaluate(webView, "window.scrollTo(0, 0);")
            await delay(0.5)
            let zoomStats = await stats(from: webView)
            outlineZooms[String(format: "%.2f", zoom)] = [
                "pageZoom": webView.pageZoom,
                "outline": zoomStats["outline"] ?? [:],
                "layout": zoomStats["layout"] ?? [:],
            ]
        }
        webView.applyPageZoom(1.0)
        await delay(0.3)

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
            "outlineAfterScroll": outlineAfterScroll,
            "outlineClick": outlineClickStats,
            "outlineExpanded": outlineExpandedStats,
            "outlineHover": outlineHover,
            "outlineZooms": outlineZooms,
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
            // macOS may replay a previous session's `odoc`/restoration events
            // for this app at launch, which would add documents the harness
            // did not create and make window counts nondeterministic. Those
            // are unrelated to the checks here, so close them.
            await delay(0.5)
            closeUnexpectedDocuments(keeping: documents)
            await delay(0.5)
            closeUnexpectedDocuments(keeping: documents)

            let ready = await waitUntil(timeout: 15) {
                controllers.allSatisfy { ($0.debugState()["outlineHeadingCount"] as? Int ?? 0) > 0 }
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
                // Headerless chrome evidence: one capture of the whole window
                // frame (traffic lights included) and one of the content view
                // (page background reaching the top edge).
                if let windowSnapshot = setting("QDOWNTEST_WINDOW_SNAPSHOT",
                                                flag: "--smoke-window-snapshot",
                                                in: arguments) {
                    extras["windowSnapshot"] = first.saveWindowSnapshot(to: windowSnapshot) ?? ""
                }
                if let contentSnapshot = setting("QDOWNTEST_CONTENT_SNAPSHOT",
                                                 flag: "--smoke-content-snapshot",
                                                 in: arguments) {
                    extras["contentSnapshot"] = first.saveContentSnapshot(to: contentSnapshot) ?? ""
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

                // Floating outline evidence for the single-document layout.
                // The bars must exist in the page and match the headings; a
                // real click on the last bar must jump and move the active bar.
                extras["outline"] = await first.evaluateForTesting(
                    "JSON.stringify(window.qdown.outlineDebug())") ?? "{}"
                let outlineClick = await first.evaluateForTesting(
                    "(function(){var b=document.querySelectorAll('#qdown-outline .qdown-outline-bar');"
                    + "if(!b.length){return false;}b[b.length-1].click();return true;})()")
                await delay(1.1)
                extras["outlineClick"] = (outlineClick as? Bool) ?? false
                extras["outlineClickScrollY"] = await first.evaluateForTesting("window.scrollY") ?? -1
                extras["outlineAfterClick"] = await first.evaluateForTesting(
                    "JSON.stringify(window.qdown.outlineDebug())") ?? "{}"

                if booleanSetting("QDOWNTEST_LINK", flag: "--smoke-link", in: arguments) {
                    first.openLinkForTesting("Tests/fixtures/other.md")
                    await delay(2.2)
                    extras["localLinkWindowTitles"] = NSApp.windows
                        .filter { $0.isVisible }
                        .map { $0.title }
                        .sorted()
                    extras["localLinkTabTitles"] = first.window?.tabGroup?.windows
                        .map { $0.title }
                        .sorted() ?? []
                    extras["localLinkDocumentWindowCount"] = documentWindowCount()
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

    // MARK: - Tabs test

    /// Opens two real documents through the production coordinator and checks
    /// that AppKit ends up with one window containing two tabs. Also exercises
    /// per-tab state, local-link tabs, and standard detach/merge.
    private static func runTabTest(arguments: [String]) {
        var paths: [String] = []
        if let environmentFiles = ProcessInfo.processInfo.environment["QDOWNTEST_FILES"], !environmentFiles.isEmpty {
            paths = environmentFiles.split(separator: "\n").map(String.init)
        } else if let index = arguments.firstIndex(of: "--tabs-test") {
            var cursor = index + 1
            while cursor < arguments.count, !arguments[cursor].hasPrefix("--") {
                paths.append(arguments[cursor])
                cursor += 1
            }
        }
        guard paths.count >= 2 else {
            fail("usage: QDOWNTEST_MODE=tabs "
                 + "QDOWNTEST_FILES=$'a.md\\nb.md' Qdown")
        }

        _ = NSDocumentController.shared
        let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }

        Task { @MainActor in
            // macOS may replay a previous session's restoration/open events.
            // Those documents are not part of this test and would add tabs
            // with no rendered content (and make the tab counts unstable).
            await delay(0.8)
            closeUnexpectedDocuments(keeping: [])
            await delay(0.4)
            closeUnexpectedDocuments(keeping: [])

            var documents: [Document] = []
            var host: NSWindow?

            for url in urls {
                let result = await openDocumentForTesting(url, host: host)
                switch result {
                case .success(let document):
                    documents.append(document)
                    if host == nil {
                        host = document.windowControllers.first?.window
                    }
                case .failure(let error):
                    fail("cannot open \(url.path): \(error.localizedDescription)")
                }
            }

            guard let hostWindow = host else { fail("no document window was created") }

            let controllers = documents.compactMap {
                $0.windowControllers.first as? DocumentWindowController
            }
            let rendered = await waitUntil(timeout: 25) {
                documents.allSatisfy { document in
                    let headings = (document.windowControllers.first as? DocumentWindowController)?
                        .debugState()["outlineHeadingCount"] as? Int ?? 0
                    return headings > 0
                }
            }
            guard rendered else { fail("tabbed documents did not render in time") }
            await delay(0.6)

            let initialWindows = hostWindow.tabGroup?.windows ?? []
            let initialTitles = initialWindows.map { $0.title }.sorted()

            var opened: [String: Any] = [
                "tabCount": initialWindows.count,
                "titles": initialTitles,
                "documentWindowCount": documentWindowCount(),
                "visibleDocumentWindowCount": visibleDocumentWindowCount(),
                "tabBarVisible": (hostWindow.windowController as? DocumentWindowController)?
                    .debugState()["tabBarVisible"] as? Bool ?? false,
                "nativeTabBarVisible": hostWindow.tabGroup?.isTabBarVisible ?? false,
                "selectedTitle": hostWindow.tabGroup?.selectedWindow?.title ?? "",
            ]

            // Chrome geometry with the native tab bar on screen. The window
            // and content snapshots are the visual evidence that AppKit's tab
            // bar spans the window and the document starts below it.
            if let hostController = hostWindow.windowController as? DocumentWindowController {
                opened["chrome"] = hostController.debugState()
                if let windowSnapshot = setting("QDOWNTEST_WINDOW_SNAPSHOT",
                                                flag: "--tabs-window-snapshot",
                                                in: arguments) {
                    opened["windowSnapshot"] = hostController.saveWindowSnapshot(to: windowSnapshot) ?? ""
                }
                if let contentSnapshot = setting("QDOWNTEST_CONTENT_SNAPSHOT",
                                                 flag: "--tabs-content-snapshot",
                                                 in: arguments) {
                    opened["contentSnapshot"] = hostController.saveContentSnapshot(to: contentSnapshot) ?? ""
                }
            }

            var perTab: [[String: Any]] = []
            for window in initialWindows {
                guard let controller = window.windowController as? DocumentWindowController else { continue }
                let state = controller.debugState()
                let mainHeading = await controller.evaluateForTesting(
                    "(function(){var h=document.querySelector('#content h1');return h?h.textContent:'';})()"
                )
                perTab.append([
                    "title": window.title,
                    "tabTitle": window.tab.title ?? window.title,
                    "outlineHeadingCount": state["outlineHeadingCount"] ?? 0,
                    "mainHeading": mainHeading ?? "",
                ])
            }
            opened["perTab"] = perTab

            // Screen-capture helper: stop right after the two-tab window is
            // stable, write its window number/geometry, and keep the process
            // alive long enough for an external `screencapture -l` to record
            // the native tab bar (which is window-server chrome and therefore
            // absent from the in-process snapshots above).
            if booleanSetting("QDOWNTEST_SCREEN_ONLY", flag: "--tabs-screen-only", in: arguments) {
                NSApp.activate(ignoringOtherApps: true)
                hostWindow.makeKeyAndOrderFront(nil)
                // Select the leading tab so the real-screen capture always
                // shows the same tab as the geometry metadata.
                if let firstWindow = initialWindows.first {
                    hostWindow.tabGroup?.selectedWindow = firstWindow
                }
                await delay(0.5)
                var screenResult: [String: Any] = [
                    "mode": "tabs-screen",
                    "opened": opened,
                    "windowNumber": hostWindow.windowNumber,
                    "windowFrame": NSStringFromRect(hostWindow.frame),
                ]
                if let screen = hostWindow.screen {
                    screenResult["screenFrame"] = NSStringFromRect(screen.frame)
                }
                if let hostController = hostWindow.windowController as? DocumentWindowController {
                    screenResult["chrome"] = hostController.debugState()
                }
                write(result: screenResult,
                      to: setting("QDOWNTEST_SCREEN_JSON", flag: "--tabs-screen-json", in: arguments),
                      label: "QDOWNTABSSCREEN")
                let hold = Double(ProcessInfo.processInfo.environment["QDOWNTEST_HOLD_SECONDS"] ?? "") ?? 0
                if hold > 0 {
                    await delay(hold)
                }
                exit(0)
            }

            // Each tab keeps its own scroll position while another tab is shown.
            var scroll: [String: Any] = [:]
            if controllers.count >= 2,
               let firstWindow = controllers[0].window,
               let secondWindow = controllers[1].window,
               let group = hostWindow.tabGroup {
                group.selectedWindow = firstWindow
                await delay(0.35)
                _ = await controllers[0].evaluateForTesting("window.scrollTo(0, 700);")
                await delay(0.45)
                let before = numberValue(await controllers[0].evaluateForTesting("window.scrollY"))
                group.selectedWindow = secondWindow
                await delay(0.5)
                let secondScroll = numberValue(await controllers[1].evaluateForTesting("window.scrollY"))
                group.selectedWindow = firstWindow
                await delay(0.5)
                let after = numberValue(await controllers[0].evaluateForTesting("window.scrollY"))
                scroll = [
                    "before": before,
                    "after": after,
                    "secondTabScrollY": secondScroll,
                    "preserved": abs(after - before) <= 5,
                ]
            }

            // A relative Markdown link opens a new tab in the same window.
            var localLink: [String: Any] = [:]
            if let first = controllers.first {
                first.openLinkForTesting("Tests/fixtures/security.md")
                let linked = await waitUntil(timeout: 20) {
                    (hostWindow.tabGroup?.windows.count ?? 0) >= 3
                }
                await delay(0.8)
                let linkWindows = hostWindow.tabGroup?.windows ?? []
                var linkTabs: [[String: Any]] = []
                for window in linkWindows {
                    guard let controller = window.windowController as? DocumentWindowController else { continue }
                    let state = controller.debugState()
                    linkTabs.append([
                        "title": window.title,
                        "outlineHeadingCount": state["outlineHeadingCount"] ?? 0,
                    ])
                }
                localLink = [
                    "rendered": linked,
                    "tabCount": linkWindows.count,
                    "titles": linkWindows.map { $0.title }.sorted(),
                    "documentWindowCount": documentWindowCount(),
                    "perTab": linkTabs,
                ]
            }

            // Standard tab detaching and merging must keep working.
            var detach: [String: Any] = [:]
            if let group = hostWindow.tabGroup, group.windows.count >= 3 {
                group.selectedWindow = group.windows.last
                await delay(0.3)
                group.windows.last?.moveTabToNewWindow(nil)
                await delay(0.7)
                detach["tabCountAfterDetach"] = group.windows.count
                detach["documentWindowCountAfterDetach"] = documentWindowCount()

                // The merge action is routed through the key window, exactly
                // like the standard Window menu item. AppKit's merge command
                // needs automatic tabbing enabled, which the harness normally
                // turns off for deterministic construction.
                NSApp.activate(ignoringOtherApps: true)
                hostWindow.makeKeyAndOrderFront(nil)
                await delay(0.4)
                let automaticTabbing = NSWindow.allowsAutomaticWindowTabbing
                NSWindow.allowsAutomaticWindowTabbing = true
                (NSApp.keyWindow ?? hostWindow).mergeAllWindows(nil)
                await delay(0.9)
                NSWindow.allowsAutomaticWindowTabbing = automaticTabbing
                detach["tabCountAfterMerge"] = hostWindow.tabGroup?.windows.count ?? 0
                detach["documentWindowCountAfterMerge"] = documentWindowCount()
            }

            // Closing tabs back down to a single document must restore the
            // headerless, tab-bar-hidden layout (safe area 28 instead of 56).
            var tabClose: [String: Any] = [:]
            if hostWindow.tabGroup != nil {
                while let current = hostWindow.tabGroup, current.windows.count > 1 {
                    current.windows.last?.close()
                    await delay(0.45)
                }
                await delay(1.0)
                let remaining = NSApp.windows.first {
                    $0.isVisible && $0.windowController is DocumentWindowController
                }
                tabClose["tabCountAfterClose"] = remaining?.tabGroup?.windows.count ?? 1
                if let controller = remaining?.windowController as? DocumentWindowController {
                    tabClose["chrome"] = controller.debugState()
                    tabClose["tabBarVisibleAfterClose"] =
                        controller.debugState()["tabBarVisible"] as? Bool ?? false
                } else {
                    tabClose["tabBarVisibleAfterClose"] = false
                }
            }

            let result: [String: Any] = [
                "mode": "tabs",
                "files": paths,
                "automaticTabbing": NSWindow.allowsAutomaticWindowTabbing,
                "opened": opened,
                "scroll": scroll,
                "localLink": localLink,
                "detach": detach,
                "tabClose": tabClose,
                "menuActions": menuActionSelectors(),
                "windowTitles": controllers.compactMap { $0.window?.title },
            ]
            write(result: result,
                  to: setting("QDOWNTEST_JSON", flag: "--tabs-json", in: arguments),
                  label: "QDOWNTABS")
            exit(0)
        }
    }

    /// Waits for documents opened through the real `application(_:open:)`
    /// event (LaunchServices / Finder double-click) and reports the resulting
    /// window/tab layout.
    private static func runLiveTabsTest(arguments: [String]) {
        let expected = Int(ProcessInfo.processInfo.environment["QDOWNTEST_EXPECT_COUNT"] ?? "") ?? 2

        Task { @MainActor in
            // Start from a clean slate: macOS may have replayed a previous
            // session's documents at launch, and those must not be mistaken
            // for the files the test script opens via LaunchServices.
            await delay(1.0)
            let restored = NSDocumentController.shared.documents
            for document in restored {
                document.close()
            }
            _ = await waitUntil(timeout: 5) {
                NSDocumentController.shared.documents.isEmpty
            }

            let arrived = await waitUntil(timeout: 30) {
                NSDocumentController.shared.documents.compactMap { $0 as? Document }.count >= expected
            }
            await delay(1.2)

            let documents = NSDocumentController.shared.documents.compactMap { $0 as? Document }
            guard arrived else {
                fail("expected \(expected) documents via open events, got \(documents.count)")
            }

            let controllers = documents.compactMap {
                $0.windowControllers.first as? DocumentWindowController
            }
            let host = controllers.first?.window
            let groupWindows = host?.tabGroup?.windows ?? controllers.compactMap { $0.window }
            let titles = groupWindows.map { $0.title }.sorted()

            var perTab: [[String: Any]] = []
            for window in groupWindows {
                guard let controller = window.windowController as? DocumentWindowController else { continue }
                let state = controller.debugState()
                perTab.append([
                    "title": window.title,
                    "tabTitle": window.tab.title ?? window.title,
                    "outlineHeadingCount": state["outlineHeadingCount"] ?? 0,
                ])
            }

            let result: [String: Any] = [
                "mode": "live-tabs",
                "documentCount": documents.count,
                "closedRestoredDocuments": restored.count,
                "documentWindowCount": documentWindowCount(),
                "visibleDocumentWindowCount": visibleDocumentWindowCount(),
                "tabCount": groupWindows.count,
                "titles": titles,
                "tabBarVisible": host.flatMap { window in
                    (window.windowController as? DocumentWindowController)?
                        .debugState()["tabBarVisible"] as? Bool
                } ?? false,
                "nativeTabBarVisible": host?.tabGroup?.isTabBarVisible ?? false,
                "chrome": host.flatMap { window in
                    (window.windowController as? DocumentWindowController)?.debugState()
                } ?? [:],
                "perTab": perTab,
                "documentURLs": documents.compactMap { $0.fileURL?.lastPathComponent },
            ]
            write(result: result,
                  to: setting("QDOWNTEST_JSON", flag: "--live-tabs-json", in: arguments),
                  label: "QDOWNTABS")
            exit(0)
        }
    }

    // MARK: - Live reload test

    /// Exercises the production `Document` + `DocumentFileWatcher` path:
    ///
    /// 1. open a real file and scroll away from the top,
    /// 2. rewrite it in place -> DOM shows the new text, scroll/zoom are kept,
    /// 3. write a sibling and `rename` it over the document (atomic save),
    /// 4. touch only the mtime -> no re-render,
    /// 5. delete the file -> the last display is kept,
    /// 6. recreate the same path -> the page reloads again.
    private static func runLiveReloadTest(arguments: [String]) {
        let fixturePath = setting("QDOWNTEST_LIVE_FILE",
                                  flag: "--live-reload-file",
                                  in: arguments)
            ?? "build/test-output/live-reload/fixture.md"
        let fileURL = URL(fileURLWithPath: fixturePath).standardizedFileURL
        let jsonPath = setting("QDOWNTEST_JSON", flag: "--live-reload-json", in: arguments)

        let initialMarker = "LIVE-MARKER-INITIAL"
        let inPlaceMarker = "LIVE-MARKER-INPLACE"
        let atomicMarker = "LIVE-MARKER-ATOMIC"
        let recreatedMarker = "LIVE-MARKER-RECREATED"

        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(liveReloadMarkdown(marker: initialMarker).utf8).write(to: fileURL, options: .atomic)
        } catch {
            fail("cannot prepare live-reload fixture: \(error.localizedDescription)")
        }

        _ = NSDocumentController.shared

        Task { @MainActor in
            // The app may have restored a previous session's documents. They
            // are not part of this test and must not interfere with the window
            // focus checks below.
            await delay(0.6)
            closeUnexpectedDocuments(keeping: [])

            let document = Document()
            document.fileURL = fileURL
            do {
                let data = try Data(contentsOf: fileURL)
                try document.read(from: data, ofType: "net.daringfireball.markdown")
            } catch {
                fail("cannot read live-reload fixture: \(error.localizedDescription)")
            }
            document.makeWindowControllers()
            guard let controller = document.windowControllers.first as? DocumentWindowController else {
                fail("live-reload document has no window controller")
            }
            controller.showWindow(nil)

            let rendered = await waitUntil(timeout: 25) {
                let state = controller.debugState()
                return (state["outlineHeadingCount"] as? Int ?? 0) > 0
                    && (state["renderCount"] as? Int ?? 0) > 0
            }
            guard rendered else { fail("live-reload document did not render in time") }
            await delay(0.5)

            controller.applyZoomForTesting(1.25)
            await delay(0.4)
            _ = await controller.evaluateForTesting("window.scrollTo(0, 900);")
            await delay(0.5)

            let initial = await liveReloadState(controller, marker: initialMarker)
            guard numberValue(initial["scrollY"]) > 0 else {
                fail("live-reload fixture is not scrollable: \(initial)")
            }
            let initialRenderCount = initial["renderCount"] as? Int ?? 0
            let keyWindowBefore = NSApp.keyWindow?.windowNumber ?? -1

            // ---- In-place write -------------------------------------------------
            do {
                try writeInPlace(fileURL, text: liveReloadMarkdown(marker: inPlaceMarker))
            } catch {
                fail("in-place write failed: \(error.localizedDescription)")
            }
            let inPlaceUpdated = await waitForLiveReload(controller,
                                                         marker: inPlaceMarker,
                                                         previousRenderCount: initialRenderCount)
            var inPlace = await liveReloadState(controller, marker: inPlaceMarker)
            inPlace["updated"] = inPlaceUpdated
            inPlace["renderCountBefore"] = initialRenderCount
            inPlace["renderCountIncreased"] =
                (inPlace["renderCount"] as? Int ?? 0) > initialRenderCount
            inPlace["scrollBefore"] = initial["scrollY"] ?? 0
            let inPlaceScrollBefore = numberValue(initial["scrollY"])
            let inPlaceScrollAfter = numberValue(inPlace["scrollY"])
            inPlace["scrollPreserved"] = inPlaceScrollBefore > 0
                && abs(inPlaceScrollAfter - inPlaceScrollBefore) <= 6
            inPlace["zoomPreserved"] = abs(numberValue(inPlace["pageZoom"]) - 1.25) < 0.01

            let afterInPlaceRenderCount = inPlace["renderCount"] as? Int ?? 0

            // ---- Atomic save: sibling file, then rename over the document ------
            do {
                try atomicReplace(fileURL, text: liveReloadMarkdown(marker: atomicMarker))
            } catch {
                fail("atomic replace failed: \(error.localizedDescription)")
            }
            let atomicUpdated = await waitForLiveReload(controller,
                                                        marker: atomicMarker,
                                                        previousRenderCount: afterInPlaceRenderCount)
            var atomic = await liveReloadState(controller, marker: atomicMarker)
            atomic["updated"] = atomicUpdated
            atomic["renderCountBefore"] = afterInPlaceRenderCount
            atomic["renderCountIncreased"] =
                (atomic["renderCount"] as? Int ?? 0) > afterInPlaceRenderCount
            atomic["scrollBefore"] = inPlace["scrollY"] ?? 0
            let atomicScrollBefore = numberValue(inPlace["scrollY"])
            let atomicScrollAfter = numberValue(atomic["scrollY"])
            atomic["scrollPreserved"] = atomicScrollBefore > 0
                && abs(atomicScrollAfter - atomicScrollBefore) <= 6
            atomic["zoomPreserved"] = abs(numberValue(atomic["pageZoom"]) - 1.25) < 0.01

            let afterAtomicRenderCount = atomic["renderCount"] as? Int ?? 0

            // ---- mtime-only change: identical bytes must not re-render ---------
            do {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(30)],
                    ofItemAtPath: fileURL.path
                )
            } catch {
                fail("mtime update failed: \(error.localizedDescription)")
            }
            await delay(1.3)
            var mtimeOnly = await liveReloadState(controller, marker: atomicMarker)
            mtimeOnly["renderCountBefore"] = afterAtomicRenderCount
            mtimeOnly["unchanged"] =
                (mtimeOnly["renderCount"] as? Int ?? 0) == afterAtomicRenderCount
            mtimeOnly["markerStillAtomic"] = mtimeOnly["markerFound"] ?? false

            // ---- Deletion keeps the last display -------------------------------
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                fail("delete failed: \(error.localizedDescription)")
            }
            await delay(1.0)
            var deleted = await liveReloadState(controller, marker: atomicMarker)
            deleted["renderCountBefore"] = afterAtomicRenderCount
            deleted["keptLastContent"] = deleted["markerFound"] ?? false
            deleted["renderCountUnchanged"] =
                (deleted["renderCount"] as? Int ?? 0) == afterAtomicRenderCount

            // ---- Recreation at the same path reloads ---------------------------
            do {
                try Data(liveReloadMarkdown(marker: recreatedMarker).utf8).write(to: fileURL)
            } catch {
                fail("recreate failed: \(error.localizedDescription)")
            }
            let recreatedUpdated = await waitForLiveReload(controller,
                                                           marker: recreatedMarker,
                                                           previousRenderCount: afterAtomicRenderCount)
            var recreated = await liveReloadState(controller, marker: recreatedMarker)
            recreated["updated"] = recreatedUpdated
            recreated["renderCountIncreased"] =
                (recreated["renderCount"] as? Int ?? 0) > afterAtomicRenderCount

            // Live reload must not activate the app or change the key window.
            let keyWindowAfter = NSApp.keyWindow?.windowNumber ?? -1
            let focus: [String: Any] = [
                "keyWindowBefore": keyWindowBefore,
                "keyWindowAfter": keyWindowAfter,
                "preserved": keyWindowBefore == keyWindowAfter,
                "appActive": NSApp.isActive,
            ]

            let result: [String: Any] = [
                "mode": "live-reload",
                "file": fileURL.path,
                "initial": initial,
                "inPlace": inPlace,
                "atomic": atomic,
                "mtimeOnly": mtimeOnly,
                "deleted": deleted,
                "recreated": recreated,
                "focus": focus,
                "logs": controller.webViewLogs,
            ]
            write(result: result, to: jsonPath, label: "QDOWNTEST")
            document.stopWatchingFile()
            exit(0)
        }
    }

    private static func liveReloadMarkdown(marker: String) -> String {
        var lines: [String] = [
            "# Live Reload \(marker)",
            "",
            "LIVE-MARKER: \(marker)",
            "",
        ]
        for index in 0..<40 {
            lines.append("## Section \(index)")
            lines.append("")
            lines.append("Paragraph \(index) for \(marker). "
                         + "The page is intentionally tall so scroll restoration is measurable.")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    private static func liveReloadState(_ controller: DocumentWindowController,
                                        marker: String) async -> [String: Any] {
        let state = controller.debugState()
        let text = await controller.evaluateForTesting(
            "document.getElementById('content').textContent") as? String ?? ""
        let scrollY = numberValue(await controller.evaluateForTesting("window.scrollY"))
        return [
            "marker": marker,
            "markerFound": text.contains(marker),
            "bodyLength": text.count,
            "scrollY": scrollY,
            "pageZoom": state["pageZoom"] ?? 0,
            "renderCount": state["renderCount"] ?? 0,
            "liveReloadCount": state["liveReloadCount"] ?? 0,
            "headingCount": state["outlineHeadingCount"] ?? 0,
        ]
    }

    @MainActor
    private static func waitForLiveReload(_ controller: DocumentWindowController,
                                          marker: String,
                                          previousRenderCount: Int,
                                          timeout: Double = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let renderCount = controller.debugState()["renderCount"] as? Int ?? 0
            let text = await controller.evaluateForTesting(
                "document.getElementById('content').textContent") as? String ?? ""
            if renderCount > previousRenderCount, text.contains(marker) {
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    /// Rewrites the file in place (no rename), which keeps the same inode and
    /// is therefore caught by the file-descriptor watcher.
    private static func writeInPlace(_ url: URL, text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.synchronize()
    }

    /// Writes a sibling file and `rename(2)`s it over the document, the way
    /// editors that save atomically do. `rename` replaces the directory entry
    /// without ever exposing a partial destination file.
    private static func atomicReplace(_ url: URL, text: String) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).qdown-\(UUID().uuidString)")
        try Data(text.utf8).write(to: temporary)
        let status = temporary.path.withCString { source in
            url.path.withCString { destination in
                rename(source, destination)
            }
        }
        if status != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw NSError(domain: "QdownLiveReload",
                          code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
        }
    }

    /// Real-screen capture harness for the single-document layout and the
    /// expanded floating outline. It opens one document, optionally scrolls to
    /// a heading and forces the outline panel open, then writes its window
    /// number so the shell script can `screencapture -l` it.
    private static func runWindowTest(arguments: [String]) {
        var paths: [String] = []
        if let environmentFiles = ProcessInfo.processInfo.environment["QDOWNTEST_FILES"],
           !environmentFiles.isEmpty {
            paths = environmentFiles.split(separator: "\n").map(String.init)
        }
        guard let path = paths.first else {
            fail("usage: QDOWNTEST_MODE=window QDOWNTEST_FILES=<file.md> Qdown")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        _ = NSDocumentController.shared

        Task { @MainActor in
            await delay(0.8)
            closeUnexpectedDocuments(keeping: [])
            await delay(0.4)
            closeUnexpectedDocuments(keeping: [])

            let opened = await openDocumentForTesting(url, host: nil)
            guard case .success(let document) = opened,
                  let window = document.windowControllers.first?.window,
                  let controller = window.windowController as? DocumentWindowController else {
                fail("cannot open \(url.path)")
            }

            let rendered = await waitUntil(timeout: 25) {
                (controller.debugState()["outlineHeadingCount"] as? Int ?? 0) > 0
            }
            guard rendered else { fail("window test document did not render in time") }
            await delay(0.8)

            window.setContentSize(NSSize(width: 1120, height: 780))
            window.center()
            if let rawZoom = ProcessInfo.processInfo.environment["QDOWNTEST_ZOOM"],
               let zoom = Double(rawZoom), zoom > 0 {
                controller.applyZoomForTesting(zoom)
                await delay(0.5)
            }
            if booleanSetting("QDOWNTEST_OUTLINE_EXPANDED",
                              flag: "--window-outline-expanded",
                              in: arguments) {
                _ = await controller.evaluateForTesting(
                    "window.qdown.scrollToHeading('qdown-heading-8');")
                await delay(0.5)
                _ = await controller.evaluateForTesting(
                    "window.qdown.setOutlineExpanded(true);")
                await delay(0.5)
            }

            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await delay(0.6)

            let outlineJSON = await controller.evaluateForTesting(
                "JSON.stringify(window.qdown.outlineDebug())") as? String ?? "{}"
            var result: [String: Any] = [
                "mode": "window",
                "outline": outlineJSON,
                "windowNumber": window.windowNumber,
                "windowFrame": NSStringFromRect(window.frame),
                "chrome": controller.debugState(),
            ]
            if let screen = window.screen {
                result["screenFrame"] = NSStringFromRect(screen.frame)
            }
            write(result: result,
                  to: setting("QDOWNTEST_SCREEN_JSON", flag: "--window-screen-json", in: arguments),
                  label: "QDOWNNWINDOW")

            let hold = Double(ProcessInfo.processInfo.environment["QDOWNTEST_HOLD_SECONDS"] ?? "") ?? 0
            if hold > 0 {
                await delay(hold)
            }
            exit(0)
        }
    }

    /// Closes documents that NSDocumentController restored from a previous
    /// session but the smoke harness did not create itself.
    @MainActor
    private static func closeUnexpectedDocuments(keeping documents: [Document]) {
        let extras = NSDocumentController.shared.documents
            .compactMap { $0 as? Document }
            .filter { candidate in
                !documents.contains { $0 === candidate }
            }
        for document in extras {
            document.close()
        }
    }

    @MainActor
    private static func openDocumentForTesting(_ url: URL,
                                               host: NSWindow?) async -> Result<Document, Error> {
        await withCheckedContinuation { continuation in
            DocumentOpenCoordinator.open(url, host: host) { result in
                continuation.resume(returning: result)
            }
        }
    }

    /// Counts virtual document windows: one per tab group, plus standalone
    /// document windows.
    @MainActor
    private static func documentWindowCount() -> Int {
        var identifiers = Set<ObjectIdentifier>()
        for window in NSApp.windows
        where window.windowController is DocumentWindowController && window.isVisible {
            if let group = window.tabGroup {
                identifiers.insert(ObjectIdentifier(group))
            } else {
                identifiers.insert(ObjectIdentifier(window))
            }
        }
        return identifiers.count
    }

    @MainActor
    private static func visibleDocumentWindowCount() -> Int {
        NSApp.windows.filter {
            $0.windowController is DocumentWindowController && $0.isVisible
        }.count
    }

    private static func menuActionSelectors() -> [String] {
        guard let mainMenu = NSApp.mainMenu else { return [] }
        var selectors: [String] = []
        for item in mainMenu.items {
            guard let submenu = item.submenu else { continue }
            for child in submenu.items {
                if let action = child.action {
                    selectors.append(NSStringFromSelector(action))
                }
            }
        }
        return selectors
    }

    private static func numberValue(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return -1
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
