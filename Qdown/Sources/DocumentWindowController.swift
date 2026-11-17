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
    private var tabObservers: [NSKeyValueObservation] = []
    private weak var observedTabGroup: NSWindowTabGroup?

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

        let window = QdownWindow(
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
        // filename lives in Qdown's own tab strip instead of the window title.
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
        observeTabGroup()
        refreshTabChrome()
        window?.makeFirstResponder(webView)
    }

    deinit {
        tabObservers.forEach { $0.invalidate() }
    }

    // MARK: - Sidebar-priority tab chrome

    /// Qdown draws its own tab strip inside the document column. The native
    /// AppKit tab bar is always suppressed: it is a full-width titlebar row
    /// that cannot be aligned with the split position and would either cover
    /// the sidebar or leave a blank band above the tabs.
    ///
    /// The native `NSWindow` tab *group* is still used for window management
    /// (selecting/closing/detaching/merging and LaunchServices opens); only its
    /// chrome is hidden.
    func refreshTabChrome() {
        guard let window else { return }
        observeTabGroup()

        guard let group = window.tabGroup else {
            applyTabChrome(windows: [window], selected: window, visible: false)
            return
        }

        let windows = group.windows
        for tabWindow in windows {
            Self.suppressNativeTabBar(in: tabWindow)
        }
        let selected = group.selectedWindow ?? window
        let visible = windows.count > 1
        for tabWindow in windows {
            guard let controller = tabWindow.windowController as? DocumentWindowController,
                  controller !== self else { continue }
            controller.applyTabChrome(windows: windows, selected: selected, visible: visible)
        }
        applyTabChrome(windows: windows, selected: selected, visible: visible)
    }

    private func applyTabChrome(windows: [NSWindow], selected: NSWindow, visible: Bool) {
        contentPane.updateTabBar(windows: windows, selected: selected, visible: visible)
    }

    private func observeTabGroup() {
        guard let window, let group = window.tabGroup else { return }
        if observedTabGroup === group, !tabObservers.isEmpty { return }
        tabObservers.forEach { $0.invalidate() }
        tabObservers.removeAll()
        observedTabGroup = group
        tabObservers.append(group.observe(\.windows, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshTabChrome() }
        })
        tabObservers.append(group.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshTabChrome() }
        })
    }

    /// Removes AppKit's native tab bar accessory (the `NSTabBar` hosted in the
    /// titlebar) while leaving the tab group itself intact. Removing it also
    /// shrinks the titlebar back to the traffic-light row, which is what lets
    /// the sidebar stay full height and the document column start at the top
    /// edge.
    static func suppressNativeTabBar(in window: NSWindow) {
        var index = window.titlebarAccessoryViewControllers.count - 1
        while index >= 0 {
            let accessory = window.titlebarAccessoryViewControllers[index]
            if containsNativeTabBar(accessory.view) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            index -= 1
        }
    }

    private static func containsNativeTabBar(_ view: NSView) -> Bool {
        if String(describing: type(of: view)) == "NSTabBar" { return true }
        return view.subviews.contains { containsNativeTabBar($0) }
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
            "tabCount": window?.tabGroup?.windows.count ?? 1,
            "tabTitles": window?.tabGroup?.windows.map { $0.title } ?? (window.map { [$0.title] } ?? []),
            "fullSizeContentView": window?.styleMask.contains(.fullSizeContentView) ?? false,
            "titlebarAppearsTransparent": window?.titlebarAppearsTransparent ?? false,
            "titleVisibilityHidden": window?.titleVisibility == .hidden,
            "titlebarSeparatorStyleNone": window.map { $0.titlebarSeparatorStyle.rawValue == 1 } ?? false,
            "titlebarHeight": window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 0,
            "contentSafeAreaTop": window?.contentView?.safeAreaInsets.top ?? 0,
            "sidebarSafeAreaTop": sidebarViewController.view.safeAreaInsets.top,
            "sidebarWidth": splitViewController.sidebarWidth,
            "contentLeft": splitViewController.contentLeftInWindow,
            "sidebarRight": splitViewController.sidebarRightInWindow,
            "sidebarDragRegionHeight": sidebarViewController.dragRegionHeight,
            "sidebarDragHandlesAcceptMouse": sidebarViewController.dragHandlesAcceptMouse,
            "contentDragRegionAcceptsMouse": contentPane.dragRegionAcceptsMouse,
            "sidebarHeaderTop": sidebarViewController.headerTopInWindow,
            "sidebarFirstRowTop": sidebarViewController.firstRowTopInWindow,
            "webViewTop": contentPane.webViewTopInWindow,
            "findBarTop": contentPane.findBarTopInWindow,
            "tabBarVisible": contentPane.tabBarVisible,
            "nativeTabBarVisible": window?.tabGroup?.isTabBarVisible ?? false,
            "tabBarTop": contentPane.tabBarTopInWindow,
            "tabBarLeft": contentPane.tabBarLeftInWindow,
            "tabBarWidth": contentPane.tabBarWidthInWindow,
            "tabBarHeight": contentPane.tabBarHeightInWindow,
            "tabBarTabCount": contentPane.tabBarTabCount,
            "tabBarTabs": contentPane.tabBarTabsForTesting,
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

    func windowDidBecomeKey(_ notification: Notification) {
        observeTabGroup()
        refreshTabChrome()
    }

    func windowDidBecomeMain(_ notification: Notification) {
        observeTabGroup()
        refreshTabChrome()
    }

    func windowWillClose(_ notification: Notification) {
        webView.clearFind()
    }
}

// MARK: - Pane container

/// Two-pane (sidebar + document) container.
///
/// The sidebar is the outermost split element and runs the full window height
/// (traffic lights sit on top of it). The document column owns Qdown's custom
/// tab strip, which starts exactly at the split position and at the window's
/// top edge. This deliberately does not use `NSSplitViewController`/
/// `NSSplitView`, whose full-height-sidebar handling is tied to AppKit's own
/// titlebar tab bar.
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

    /// X position of the sidebar's right edge (the split position) in window
    /// coordinates. The custom tab strip starts exactly here.
    var sidebarRightInWindow: CGFloat {
        guard let window = view.window, let content = window.contentView else { return -1 }
        view.layoutSubtreeIfNeeded()
        let rect = splitView.sidebarViewFrame
        return splitView.convert(rect, to: content).maxX
    }

    /// X position where the document column (Find bar and WebView) starts.
    /// It is the split position plus the 5pt divider hit area. Only the tab
    /// strip extends left over the divider, so the single-document layout is
    /// unchanged.
    var contentLeftInWindow: CGFloat {
        guard let window = view.window, let content = window.contentView else { return -1 }
        view.layoutSubtreeIfNeeded()
        let rect = splitView.contentViewFrame
        return splitView.convert(rect, to: content).minX
    }
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
    private let sidebarView: NSView
    private let contentView: NSView

    init(sidebarView: NSView, contentView: NSView) {
        let storedWidth = min(max(Self.storedSidebarWidth(),
                                  Self.minimumSidebarWidth),
                              Self.maximumSidebarWidth)
        self.sidebarWidth = storedWidth
        self.sidebarView = sidebarView
        self.contentView = contentView
        self.widthConstraint = sidebarView.widthAnchor.constraint(equalToConstant: storedWidth)
        super.init(frame: .zero)

        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        dividerView.translatesAutoresizingMaskIntoConstraints = false

        // Keep the original document-column origin (after the 5pt divider hit
        // area) so the single-document, headerless layout is pixel-identical
        // to before. The custom tab strip extends 5pt to the left over the
        // divider, so its own left edge lands exactly on the split position.
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

    var sidebarViewFrame: NSRect { sidebarView.frame }
    var contentViewFrame: NSRect { contentView.frame }

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

// MARK: - Custom tab strip

/// One entry in the document-column tab strip. The window reference is weak so
/// the tab strip does not keep sibling tab windows alive.
private final class DocumentTabBarItem {
    weak var window: NSWindow?
    let title: String

    init(window: NSWindow, title: String) {
        self.window = window
        self.title = title
    }
}

/// Qdown's own single-row tab strip, drawn inside the document column.
///
/// It deliberately replaces AppKit's native titlebar tab bar: the native bar
/// lives in its own titlebar row (leaving a blank band above the tabs) and is
/// laid out for the whole window. This view starts at the split position and
/// at the window's top edge, so the sidebar keeps its full-height priority.
final class DocumentTabBarView: NSView {

    static let preferredHeight: CGFloat = 34
    static let emptyBarDragPoint: CGFloat = 6

    var onSelect: ((NSWindow) -> Void)?
    var onClose: ((NSWindow) -> Void)?

    private var items: [DocumentTabBarItem] = []
    private weak var selectedWindow: NSWindow?
    private var tabRects: [NSRect] = []
    private var closeRects: [NSRect] = []

    private let barColor = NSColor(srgbRed: 0.871, green: 0.867, blue: 0.906, alpha: 1.0)
    private let unselectedTabColor = NSColor(srgbRed: 0.902, green: 0.898, blue: 0.933, alpha: 1.0)
    private let selectedTabColor = NSColor(srgbRed: 0.976, green: 0.976, blue: 0.992, alpha: 1.0)
    private let accentColor = NSColor(srgbRed: 0.478, green: 0.243, blue: 0.616, alpha: 1.0)
    private let separatorColor = NSColor(srgbRed: 0.769, green: 0.718, blue: 0.843, alpha: 0.7)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(windows: [NSWindow], selected: NSWindow) {
        items = windows.map {
            DocumentTabBarItem(window: $0, title: $0.tab.title ?? $0.title)
        }
        selectedWindow = selected
        needsLayout = true
        needsDisplay = true
    }

    var tabCount: Int { items.count }

    var tabFramesForTesting: [NSRect] { tabRects }

    override func layout() {
        super.layout()
        let count = items.count
        guard count > 0, bounds.width > 0 else {
            tabRects = []
            closeRects = []
            return
        }
        // Equal width, equal height, one single row. Very large tab counts
        // shrink the tabs instead of wrapping onto a second row.
        let perTab = bounds.width / CGFloat(count)
        let width = min(220, max(90, perTab))
        let height = bounds.height
        tabRects = (0..<count).map { index in
            NSRect(x: CGFloat(index) * width, y: 0, width: width, height: height)
        }
        closeRects = tabRects.map { rect in
            NSRect(x: rect.maxX - 22, y: (height - 16) / 2, width: 16, height: 16)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        barColor.setFill()
        bounds.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        for (index, item) in items.enumerated() where index < tabRects.count {
            let rect = tabRects[index]
            let selected = item.window === selectedWindow
            (selected ? selectedTabColor : unselectedTabColor).setFill()
            rect.fill()

            if selected {
                accentColor.setFill()
                NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2).fill()
            }

            separatorColor.setFill()
            NSRect(x: rect.maxX - 0.5, y: 0, width: 0.5, height: rect.height).fill()

            let font = NSFont.systemFont(ofSize: 12, weight: selected ? .medium : .regular)
            let textColor = selected
                ? NSColor(srgbRed: 0.20, green: 0.20, blue: 0.24, alpha: 1.0)
                : NSColor(srgbRed: 0.37, green: 0.37, blue: 0.42, alpha: 1.0)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraph,
            ]
            let textRect = NSRect(x: rect.minX + 12, y: 0,
                                  width: max(0, rect.width - 40), height: rect.height)
            (item.title as NSString).draw(in: textRect, withAttributes: attributes)

            // A small close affordance on every tab. Clicking it closes that
            // document (and therefore removes the tab).
            let closeAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(srgbRed: 0.45, green: 0.42, blue: 0.53, alpha: 0.85),
            ]
            let closeRect = closeRects[index]
            let closeSize = ("×" as NSString).size(withAttributes: closeAttributes)
            ("×" as NSString).draw(
                at: NSPoint(x: closeRect.midX - closeSize.width / 2,
                            y: closeRect.midY - closeSize.height / 2),
                withAttributes: closeAttributes
            )
        }

        // One continuous 1pt rule along the bottom of the whole document
        // column, so the tab row reads as a single band even after the last
        // tab.
        separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in tabRects {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (index, rect) in tabRects.enumerated() where rect.contains(point) {
            guard let target = items[index].window else { return }
            if closeRects[index].contains(point) {
                onClose?(target)
            } else {
                onSelect?(target)
            }
            return
        }
        // Empty part of the tab row behaves like the headerless drag strip.
        window?.performDrag(with: event)
    }
}

/// Qdown's window subclass keeps AppKit's native tab bar suppressed. The
/// native tab group is still what drives window tabs, but its titlebar chrome
/// would reintroduce the blank band and the full-width strip that the
/// sidebar-priority layout forbids.
final class QdownWindow: NSWindow {

    override func toggleTabBar(_ sender: Any?) {
        (windowController as? DocumentWindowController)?.refreshTabChrome()
    }

    override func addTabbedWindow(_ window: NSWindow, ordered place: NSWindow.OrderingMode) {
        super.addTabbedWindow(window, ordered: place)
        DocumentWindowController.suppressNativeTabBar(in: window)
        if let group = tabGroup {
            for member in group.windows {
                DocumentWindowController.suppressNativeTabBar(in: member)
            }
        }
        (windowController as? DocumentWindowController)?.refreshTabChrome()
    }

    override func mergeAllWindows(_ sender: Any?) {
        super.mergeAllWindows(sender)
        if let group = tabGroup {
            for member in group.windows {
                DocumentWindowController.suppressNativeTabBar(in: member)
            }
        }
        (windowController as? DocumentWindowController)?.refreshTabChrome()
    }
}
