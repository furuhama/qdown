import AppKit
import WebKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

    /// All Qdown document windows share this identifier so AppKit can merge
    /// them into native window tabs (and so a detached tab can be re-merged).
    static let tabbingIdentifier = "QdownDocument"

    let qdownDocument: Document
    private let sidebarViewController: SidebarViewController
    private let contentPane: ContentViewController
    private let splitViewController: DocumentSplitViewController
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
        let sidebarViewController = SidebarViewController()
        let contentPane = ContentViewController(webView: webView)
        self.sidebarViewController = sidebarViewController
        self.contentPane = contentPane
        self.splitViewController = DocumentSplitViewController(
            sidebarViewController: sidebarViewController,
            contentViewController: contentPane
        )

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
        // Headerless chrome: the content view (sidebar + page background) runs
        // all the way to the top edge, the titlebar is transparent, and the
        // filename lives in the native tab bar instead of the window title.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false

        super.init(window: window)

        window.delegate = self

        // A plain two-pane container is used instead of NSSplitViewController
        // on purpose. AppKit treats any NSSplitView as a full-height sidebar
        // and lays the native window tab bar out only over the content pane,
        // which leaves a blank strip above the sidebar. A custom pane
        // container keeps the native tab bar spanning the whole window.
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
        saveSnapshot(of: sidebarViewController.view, to: path)
    }

    /// Captures the whole window frame, including the transparent titlebar and
    /// the traffic-light buttons. This is the visual proof that no opaque gray
    /// header row is drawn above the content.
    func saveWindowSnapshot(to path: String) -> String? {
        guard let window, let themeFrame = window.contentView?.superview else { return nil }
        return saveSnapshot(of: themeFrame, to: path)
    }

    /// Captures the content view only (sidebar + page); unlike the theme-frame
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
            "sidebarHeadings": sidebarViewController.headingCount,
            "pageZoom": webView.pageZoom,
            "findVisible": contentPane.isFindVisible,
            "findQuery": contentPane.findBar.searchField.stringValue,
            "findCountText": contentPane.findBar.debugCountText,
            "viewerReady": webView.isViewerReady,
            "windowCount": NSApp.windows.filter { $0.isVisible }.count,
            "tabCount": window?.tabbedWindows?.count ?? 1,
            "tabTitles": window?.tabbedWindows?.map { $0.title } ?? (window.map { [$0.title] } ?? []),
            "fullSizeContentView": window?.styleMask.contains(.fullSizeContentView) ?? false,
            "titlebarAppearsTransparent": window?.titlebarAppearsTransparent ?? false,
            "titleVisibilityHidden": window?.titleVisibility == .hidden,
            "titlebarSeparatorStyleNone": window.map { $0.titlebarSeparatorStyle.rawValue == 1 } ?? false,
            "titlebarHeight": window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 0,
            "contentSafeAreaTop": window?.contentView?.safeAreaInsets.top ?? 0,
            "sidebarSafeAreaTop": sidebarViewController.view.safeAreaInsets.top,
            "sidebarWidth": splitViewController.sidebarWidth,
            "sidebarDragRegionHeight": sidebarViewController.dragRegionHeight,
            "sidebarDragHandlesAcceptMouse": sidebarViewController.dragHandlesAcceptMouse,
            "contentDragRegionAcceptsMouse": contentPane.dragRegionAcceptsMouse,
            "sidebarHeaderTop": sidebarViewController.headerTopInWindow,
            "sidebarFirstRowTop": sidebarViewController.firstRowTopInWindow,
            "webViewTop": contentPane.webViewTopInWindow,
            "findBarTop": contentPane.findBarTopInWindow,
            "tabBarVisible": window?.tabGroup?.isTabBarVisible ?? false,
            "windowNumber": window?.windowNumber ?? -1,
            "titlebarSeparatorStyle": window.map { Int($0.titlebarSeparatorStyle.rawValue) } ?? -1,
        ]
        if let window {
            state["windowFrame"] = NSStringFromRect(window.frame)
        }
        return state
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        webView.clearFind()
    }
}

// MARK: - Pane container

/// Two-pane (sidebar + document) container.
///
/// This deliberately does not use `NSSplitViewController`/`NSSplitView`.
/// AppKit treats any split view as a full-height sidebar and then lays the
/// native window tab bar out only over the content pane, leaving the strip
/// above the sidebar blank. A plain pane container keeps the native tab bar
/// spanning the entire window while preserving the sidebar/content split and
/// the headerless window chrome.
final class DocumentSplitViewController: NSViewController {

    private let sidebarViewController: SidebarViewController
    private let contentViewController: ContentViewController
    private let splitView: DocumentSplitView

    init(sidebarViewController: SidebarViewController,
         contentViewController: ContentViewController) {
        self.sidebarViewController = sidebarViewController
        self.contentViewController = contentViewController
        self.splitView = DocumentSplitView(sidebarView: sidebarViewController.view,
                                           contentView: contentViewController.view)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = splitView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(sidebarViewController)
        addChild(contentViewController)
    }

    var sidebarWidth: CGFloat { splitView.sidebarWidth }
}

/// The actual split layout: a fixed-width sidebar, a 1pt separator with a
/// wider hit area, and a flexible content pane.
final class DocumentSplitView: NSView {

    static let minimumSidebarWidth: CGFloat = 180
    static let maximumSidebarWidth: CGFloat = 420
    static let minimumContentWidth: CGFloat = 320
    static let dividerHitWidth: CGFloat = 5

    private(set) var sidebarWidth: CGFloat
    private let widthConstraint: NSLayoutConstraint
    private let dividerView = SplitDividerView()

    init(sidebarView: NSView, contentView: NSView) {
        let storedWidth = min(max(Self.storedSidebarWidth(),
                                  Self.minimumSidebarWidth),
                              Self.maximumSidebarWidth)
        self.sidebarWidth = storedWidth
        self.widthConstraint = sidebarView.widthAnchor.constraint(equalToConstant: storedWidth)
        super.init(frame: .zero)

        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        dividerView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(sidebarView)
        addSubview(dividerView)
        addSubview(contentView)

        NSLayoutConstraint.activate([
            sidebarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,

            dividerView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            dividerView.topAnchor.constraint(equalTo: topAnchor),
            dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dividerView.widthAnchor.constraint(equalToConstant: Self.dividerHitWidth),

            contentView.leadingAnchor.constraint(equalTo: dividerView.trailingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumContentWidth),
        ])

        dividerView.onDrag = { [weak self] delta in
            guard let self else { return }
            self.setSidebarWidth(self.sidebarWidth + delta)
        }
        dividerView.onDragEnded = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(self.sidebarWidth), forKey: "QdownSidebarWidth")
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // Keep the sidebar inside its bounds when the window is made narrow.
        guard bounds.width > 0 else { return }
        let maximum = maximumSidebarWidth
        if widthConstraint.constant > maximum + 0.5 {
            widthConstraint.constant = maximum
            sidebarWidth = maximum
        }
    }

    private var maximumSidebarWidth: CGFloat {
        max(Self.minimumSidebarWidth,
            min(Self.maximumSidebarWidth,
                bounds.width - Self.minimumContentWidth - Self.dividerHitWidth))
    }

    private func setSidebarWidth(_ width: CGFloat) {
        let clamped = min(max(width, Self.minimumSidebarWidth), maximumSidebarWidth)
        sidebarWidth = clamped
        widthConstraint.constant = clamped
    }

    /// Continues the width chosen with the old NSSplitView autosave. The
    /// previous stored value is a frame string such as
    /// `"0.000000, 0.000000, 230.000000, 808.000000, NO, NO"`.
    private static func storedSidebarWidth() -> CGFloat {
        let defaults = UserDefaults.standard
        if let width = defaults.object(forKey: "QdownSidebarWidth") as? NSNumber {
            return CGFloat(width.doubleValue)
        }
        if let frames = defaults.stringArray(forKey: "NSSplitView Subview Frames QdownSplitView"),
           let first = frames.first {
            let parts = first.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count >= 3, let width = Double(parts[2]) {
                return CGFloat(width)
            }
        }
        return 230
    }
}

/// A transparent 5pt hit area with a 1pt separator line, used to resize the
/// sidebar without bringing back `NSSplitView`.
final class SplitDividerView: NSView {

    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private var lastX: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        lastX = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let delta = x - lastX
        lastX = x
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}
