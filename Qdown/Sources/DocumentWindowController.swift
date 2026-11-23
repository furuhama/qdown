import AppKit
import WebKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

    /// All Qdown document windows share this identifier so AppKit can merge
    /// them into native window tabs (and so a detached tab can be re-merged).
    static let tabbingIdentifier = "QdownDocument"

    let qdownDocument: Document
    private let contentPane: ContentViewController
    private let webView: MarkdownWebView
    private var zoomStore = ZoomStore()

    private(set) var webViewLogs: [String] = []
    /// Number of headings in the rendered document. Kept on the native side so
    /// tests and diagnostics can wait for the first render without going
    /// through JavaScript. The heading navigation itself lives in the page's
    /// floating outline.
    private(set) var headingCount = 0

    /// Counts completed renders (initial plus live reloads). Diagnostics use
    /// this to prove that a disk change actually re-rendered the page.
    private(set) var renderCount = 0
    private var liveReloadInFlight = false

    init(document: Document) {
        self.qdownDocument = document
        let directory = qdownDocument.fileURL?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser

        let webView = MarkdownWebView(documentDirectory: directory,
                                      resourceDirectory: Bundle.main.resourceURL ?? directory)
        self.webView = webView
        let contentPane = ContentViewController(webView: webView)
        self.contentPane = contentPane

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = qdownDocument.fileURL?.lastPathComponent ?? "Qdown"
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 400)
        window.backgroundColor = NSColor(srgbRed: 0.941, green: 0.941, blue: 0.969, alpha: 1.0)
        // Headerless chrome: the page background runs all the way to the top
        // edge and the filename lives in AppKit's native tab bar instead of the
        // window title. With a single document AppKit hides the tab bar and
        // only the 28pt traffic-light strip remains.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false

        super.init(window: window)

        window.delegate = self

        // The window's content is the document pane itself; the native tab bar
        // is AppKit chrome and is never part of this hierarchy.
        window.contentViewController = contentPane

        if !window.setFrameUsingName("QdownDocumentWindow") {
            window.setContentSize(NSSize(width: 1120, height: 780))
            window.center()
        }
        window.setFrameAutosaveName("QdownDocumentWindow")

        webView.onHeadings = { [weak self] headings in
            self?.headingCount = headings.count
        }

        webView.onOpenLink = { [weak self] href in
            self?.openLink(href)
        }

        webView.onDropFiles = { [weak self] urls in
            self?.openDroppedFiles(urls)
        }

        webView.onLog = { [weak self] message in
            self?.webViewLogs.append(message)
        }

        webView.onRenderDone = { [weak self] _ in
            guard let self else { return }
            self.renderCount += 1
            if self.liveReloadInFlight {
                // Search state does not survive a live reload. Clear it without
                // moving focus; re-running find would also scroll away from the
                // restored reading position.
                self.liveReloadInFlight = false
                self.contentPane.resetFindForReload()
            } else {
                self.contentPane.refreshFindIfNeeded()
            }
        }

        webView.applyPageZoom(zoomStore.zoom)
        webView.render(markdown: qdownDocument.markdown, baseDirectory: directory)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        updateTitle()
        super.showWindow(sender)
        // Fallback for window controllers shown outside the normal
        // Document.makeWindowControllers path; the makeWindowControllers hook
        // covers NSDocumentController's own Finder/Apple Event opens.
        if let window {
            DocumentOpenCoordinator.attachToExistingWindow(window)
        }
        window?.makeFirstResponder(webView)
    }

    private func updateTitle() {
        let name = qdownDocument.fileURL?.lastPathComponent ?? "Qdown"
        window?.title = name
        window?.tab.title = name
        window?.tab.toolTip = qdownDocument.fileURL?.path
        window?.representedURL = qdownDocument.fileURL
    }

    // MARK: - Links

    private func openLink(_ href: String) {
        guard let baseDirectory = qdownDocument.fileURL?.deletingLastPathComponent() else { return }
        switch LinkRouter.resolve(href, relativeTo: baseDirectory) {
        case .external(let url):
            NSWorkspace.shared.open(url)
        case .localFile(let url):
            openLocalFile(url)
        case .unsupported:
            break
        }
    }

    private func openLocalFile(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            NSSound.beep()
            return
        }

        let extensionName = url.pathExtension.lowercased()
        if ["md", "markdown", "txt"].contains(extensionName) {
            // Local Markdown links open as a new tab in this same window.
            DocumentOpenCoordinator.open(url, host: window) { [weak self] result in
                if case .failure(let error) = result { self?.showOpenError(error) }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func openDroppedFiles(_ urls: [URL]) {
        let accepted = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return url.isFileURL && ["md", "markdown", "txt"].contains(ext)
        }
        guard !accepted.isEmpty else {
            NSSound.beep()
            return
        }
        DocumentOpenCoordinator.open(accepted, host: window) { [weak self] result in
            if case .failure(let error) = result { self?.showOpenError(error) }
        }
    }

    private func showOpenError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Qdown could not open the document."
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - Find

    @objc func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? Int(NSFindPanelAction.showFindPanel.rawValue)
        switch tag {
        case Int(NSFindPanelAction.showFindPanel.rawValue):
            contentPane.showFind()
        case Int(NSFindPanelAction.next.rawValue):
            contentPane.findNext()
        case Int(NSFindPanelAction.previous.rawValue):
            contentPane.findPrevious()
        default:
            break
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if contentPane.isFindVisible {
            contentPane.hideFind()
        } else {
            super.cancelOperation(sender)
        }
    }

    // MARK: - Zoom

    @objc func zoomIn(_ sender: Any?) {
        applyZoom(zoomStore.increased())
    }

    @objc func zoomOut(_ sender: Any?) {
        applyZoom(zoomStore.decreased())
    }

    @objc func actualSize(_ sender: Any?) {
        applyZoom(1.0)
    }

    private func applyZoom(_ value: Double) {
        zoomStore.zoom = value
        webView.applyPageZoom(value)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(zoomIn(_:)) {
            return zoomStore.zoom < (ZoomStore.steps.last ?? 2.5) - 0.001
        }
        if menuItem.action == #selector(zoomOut(_:)) {
            return zoomStore.zoom > (ZoomStore.steps.first ?? 0.5) + 0.001
        }
        return true
    }

    // MARK: - Live reload

    /// Re-renders the document after its file changed on disk. The WebView
    /// keeps its page zoom, and the page itself saves/restores the scroll
    /// position around the DOM replacement. No window is activated or made
    /// key, so background tabs update without taking focus.
    func applyLiveReload() {
        guard let baseDirectory = qdownDocument.fileURL?.deletingLastPathComponent() else {
            return
        }
        liveReloadInFlight = true
        webView.render(markdown: qdownDocument.markdown, baseDirectory: baseDirectory)
    }

    // MARK: - Debug / smoke test

    func findForTesting(_ query: String) {
        contentPane.setFindForTesting(query)
    }

    func openLinkForTesting(_ href: String) {
        openLink(href)
    }

    func applyZoomForTesting(_ value: Double) {
        applyZoom(value)
    }

    func evaluateForTesting(_ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }

    /// Captures the whole window frame, including the transparent titlebar,
    /// the native tab bar, and the traffic-light buttons. This is the visual
    /// proof that no opaque gray header row is drawn above the content.
    func saveWindowSnapshot(to path: String) -> String? {
        guard let window, let themeFrame = window.contentView?.superview else { return nil }
        return saveSnapshot(of: themeFrame, to: path)
    }

    /// Captures the content view only (page + WebView); unlike the theme-frame
    /// snapshot this does not depend on private AppKit titlebar rendering.
    func saveContentSnapshot(to path: String) -> String? {
        guard let contentView = window?.contentView else { return nil }
        return saveSnapshot(of: contentView, to: path)
    }

    private func saveSnapshot(of view: NSView, to path: String) -> String? {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try png.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    func debugState() -> [String: Any] {
        var state: [String: Any] = [
            "title": window?.title ?? "",
            "tabTitle": window?.tab.title ?? "",
            "outlineHeadingCount": headingCount,
            "pageZoom": webView.pageZoom,
            "findVisible": contentPane.isFindVisible,
            "findQuery": contentPane.findBar.searchField.stringValue,
            "findCountText": contentPane.findBar.debugCountText,
            "viewerReady": webView.isViewerReady,
            "renderCount": renderCount,
            "liveReloadCount": qdownDocument.liveReloadCount,
            "liveReloadInFlight": liveReloadInFlight,
            "windowCount": NSApp.windows.filter { $0.isVisible }.count,
            "tabCount": window?.tabGroup?.windows.count ?? 1,
            "tabTitles": window?.tabGroup?.windows.map { $0.title } ?? (window.map { [$0.title] } ?? []),
            "fullSizeContentView": window?.styleMask.contains(.fullSizeContentView) ?? false,
            "titlebarAppearsTransparent": window?.titlebarAppearsTransparent ?? false,
            "titleVisibilityHidden": window?.titleVisibility == .hidden,
            "titlebarSeparatorStyleNone": window.map { $0.titlebarSeparatorStyle.rawValue == 1 } ?? false,
            "titlebarHeight": window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 0,
            "contentSafeAreaTop": window?.contentView?.safeAreaInsets.top ?? 0,
            "contentDragRegionAcceptsMouse": contentPane.dragRegionAcceptsMouse,
            "contentDragRegionHitIsDragHandle": contentPane.dragRegionHitIsDragHandle,
            "contentDragRegionHeight": contentPane.dragRegionHeight,
            "contentDragRegionTopInWindow": contentPane.dragRegionTopInWindow,
            "contentDragRegionHandoff": WindowDragView.dragHandoff,
            "webViewTop": contentPane.webViewTopInWindow,
            "findBarTop": contentPane.findBarTopInWindow,
            // AppKit owns the tab bar now. With one document it is hidden and
            // the safe area collapses back to the 28pt traffic-light strip.
            "tabBarVisible": window?.tabGroup?.isTabBarVisible ?? false,
            "nativeTabBarVisible": window?.tabGroup?.isTabBarVisible ?? false,
            "windowNumber": window?.windowNumber ?? -1,
            "titlebarSeparatorStyle": window.map { Int($0.titlebarSeparatorStyle.rawValue) } ?? -1,
        ]
        if let window {
            state["windowFrame"] = NSStringFromRect(window.frame)
            state["windowSize"] = NSStringFromSize(window.frame.size)
        }
        return state
    }

    // MARK: - NSWindowDelegate

    func windowDidChangeScreen(_ notification: Notification) {
        // The titlebar/tab-bar safe area is screen-dependent. Resolve it again
        // on the new screen; never carry over geometry from the previous one.
        contentPane.refreshScreenGeometry()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        // A Retina <-> non-Retina move changes backingScaleFactor. Re-layout
        // and redraw so no view keeps rendering at the old scale.
        contentPane.refreshScreenGeometry()
    }

    func windowWillClose(_ notification: Notification) {
        webView.clearFind()
        qdownDocument.stopWatchingFile()
    }
}
