import AppKit
import WebKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

    let qdownDocument: Document
    private let sidebarViewController: SidebarViewController
    private let contentPane: ContentViewController
    private let webView: MarkdownWebView
    private var zoomStore = ZoomStore()

    private(set) var webViewLogs: [String] = []

    init(document: Document) {
        self.qdownDocument = document
        let directory = qdownDocument.fileURL?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser

        let webView = MarkdownWebView(documentDirectory: directory,
                                      resourceDirectory: Bundle.main.resourceURL ?? directory)
        self.webView = webView
        self.sidebarViewController = SidebarViewController()
        self.contentPane = ContentViewController(webView: webView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = qdownDocument.fileURL?.lastPathComponent ?? "Qdown"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 400)
        window.backgroundColor = NSColor(srgbRed: 0.941, green: 0.941, blue: 0.969, alpha: 1.0)
        window.titlebarAppearsTransparent = false

        super.init(window: window)

        window.delegate = self

        let splitViewController = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(viewController: sidebarViewController)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)

        let contentItem = NSSplitViewItem(viewController: contentPane)
        contentItem.canCollapse = false
        contentItem.minimumThickness = 320

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.autosaveName = "QdownSplitView"

        window.contentViewController = splitViewController

        if !window.setFrameUsingName("QdownDocumentWindow") {
            window.setContentSize(NSSize(width: 1120, height: 780))
            window.center()
        }
        window.setFrameAutosaveName("QdownDocumentWindow")

        sidebarViewController.onSelectHeading = { [weak self] id in
            self?.webView.scrollToHeading(id: id)
        }

        webView.onHeadings = { [weak self] headings in
            self?.sidebarViewController.update(headings: headings)
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
            self?.contentPane.refreshFindIfNeeded()
        }

        webView.pageZoom = zoomStore.zoom
        webView.render(markdown: qdownDocument.markdown, baseDirectory: directory)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        updateTitle()
        super.showWindow(sender)
        window?.makeFirstResponder(webView)
    }

    private func updateTitle() {
        window?.title = qdownDocument.fileURL?.lastPathComponent ?? "Qdown"
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
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] _, _, error in
                if let error { self?.showOpenError(error) }
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
        for url in accepted {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] _, _, error in
                if let error { self?.showOpenError(error) }
            }
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
        webView.pageZoom = value
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

    // MARK: - Debug / smoke test

    func findForTesting(_ query: String) {
        contentPane.setFindForTesting(query)
    }

    func openLinkForTesting(_ href: String) {
        openLink(href)
    }

    func clickSidebarHeadingForTesting(id: String) -> Bool {
        sidebarViewController.clickHeadingForTesting(id: id)
    }

    func evaluateForTesting(_ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }

    func saveSidebarSnapshot(to path: String) -> String? {
        let sidebarView = sidebarViewController.view
        sidebarView.layoutSubtreeIfNeeded()
        guard let bitmap = sidebarView.bitmapImageRepForCachingDisplay(in: sidebarView.bounds) else {
            return nil
        }
        sidebarView.cacheDisplay(in: sidebarView.bounds, to: bitmap)
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
        [
            "title": window?.title ?? "",
            "sidebarHeadings": sidebarViewController.headingCount,
            "pageZoom": webView.pageZoom,
            "findVisible": contentPane.isFindVisible,
            "findQuery": contentPane.findBar.searchField.stringValue,
            "findCountText": contentPane.findBar.debugCountText,
            "viewerReady": webView.isViewerReady,
            "windowCount": NSApp.windows.filter { $0.isVisible }.count,
        ]
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        webView.clearFind()
    }
}
