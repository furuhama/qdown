import AppKit

final class FindBarView: NSView, NSSearchFieldDelegate {

    let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    var debugCountText: String { countLabel.stringValue }

    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.98, alpha: 1.0).cgColor

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "検索"
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.controlSize = .small
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let preferredSearchWidth = searchField.widthAnchor.constraint(equalToConstant: 260)
        preferredSearchWidth.priority = .defaultHigh
        preferredSearchWidth.isActive = true
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = NSColor(srgbRed: 0.4, green: 0.4, blue: 0.45, alpha: 1.0)
        countLabel.alignment = .left
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let preferredCountWidth = countLabel.widthAnchor.constraint(equalToConstant: 80)
        preferredCountWidth.priority = .defaultHigh
        preferredCountWidth.isActive = true
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true

        configure(button: previousButton,
                  symbol: "chevron.up",
                  tooltip: "前のマッチ (⇧⌘G)",
                  action: #selector(previousPressed(_:)))
        configure(button: nextButton,
                  symbol: "chevron.down",
                  tooltip: "次のマッチ (⌘G)",
                  action: #selector(nextPressed(_:)))
        configure(button: closeButton,
                  symbol: "xmark",
                  tooltip: "検索を閉じる",
                  action: #selector(closePressed(_:)))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [searchField, countLabel, spacer, previousButton, nextButton, closeButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.distribution = .fill
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 24),
            nextButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
        ])

        update(count: 0, current: 0, query: "")
    }

    private func configure(button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.contentTintColor = NSColor(srgbRed: 0.439, green: 0.337, blue: 0.592, alpha: 1.0)
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(srgbRed: 0.769, green: 0.718, blue: 0.843, alpha: 0.7).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func focus() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    func update(count: Int, current: Int, query: String) {
        if query.isEmpty {
            countLabel.stringValue = ""
        } else if count == 0 {
            countLabel.stringValue = "0 件"
        } else {
            countLabel.stringValue = "\(max(current, 1))/\(count) 件"
        }
        previousButton.isEnabled = count > 0
        nextButton.isEnabled = count > 0
    }

    // MARK: - Actions

    @objc private func previousPressed(_ sender: Any?) {
        onPrevious?()
    }

    @objc private func nextPressed(_ sender: Any?) {
        onNext?()
    }

    @objc private func closePressed(_ sender: Any?) {
        onClose?()
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        onQueryChange?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            onPrevious?()
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            onNext?()
            return true
        }
        return false
    }
}

final class ContentViewController: NSViewController {

    let webView: MarkdownWebView
    let findBar = FindBarView()
    let tabBar = DocumentTabBarView()
    private let topDragView = WindowDragView()
    private var stackTopToSafeArea: NSLayoutConstraint!
    private var stackTopBelowTabBar: NSLayoutConstraint!
    private(set) var tabBarVisible = false
    private(set) var tabBarTabCount = 0

    private var findQuery = ""

    init(webView: MarkdownWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 700))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(srgbRed: 0.941, green: 0.941, blue: 0.969, alpha: 1.0).cgColor

        topDragView.translatesAutoresizingMaskIntoConstraints = false
        topDragView.wantsLayer = true
        topDragView.layer?.backgroundColor = NSColor(srgbRed: 0.941, green: 0.941, blue: 0.969, alpha: 1.0).cgColor
        findBar.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        webView.setContentHuggingPriority(.defaultLow, for: .vertical)
        webView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let stack = NSStackView(views: [findBar, webView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.distribution = .fill
        stack.detachesHiddenViews = true
        root.addSubview(topDragView)
        root.addSubview(stack)
        // The tab strip is added last so it sits on top of the drag strip and
        // can receive clicks while occupying the window's top edge.
        root.addSubview(tabBar)

        stackTopToSafeArea = stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor)
        stackTopBelowTabBar = stack.topAnchor.constraint(equalTo: tabBar.bottomAnchor)
        stackTopToSafeArea.isActive = true
        tabBar.isHidden = true

        NSLayoutConstraint.activate([
            // The page background reaches the window's top edge, while the
            // find bar and WebView start below the titlebar/tab strip. When
            // tabs are visible the stack starts at the bottom of Qdown's own
            // tab strip instead of the titlebar safe area.
            topDragView.topAnchor.constraint(equalTo: root.topAnchor),
            topDragView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topDragView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topDragView.bottomAnchor.constraint(equalTo: stack.topAnchor),

            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            // Extend over the divider hit area so the strip's left edge is the
            // split position (the sidebar's right edge), not 5pt to its right.
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                            constant: -DocumentSplitView.dividerHitWidth),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: DocumentTabBarView.preferredHeight),

            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            findBar.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            webView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])

        tabBar.onSelect = { [weak self] window in
            self?.selectTab(window)
        }
        tabBar.onClose = { window in
            window.performClose(nil)
        }

        findBar.isHidden = true
        findBar.onQueryChange = { [weak self] query in
            self?.findQuery = query
            self?.runFind(query: query)
        }
        findBar.onNext = { [weak self] in
            self?.findNext()
        }
        findBar.onPrevious = { [weak self] in
            self?.findPrevious()
        }
        findBar.onClose = { [weak self] in
            self?.hideFind()
        }

        view = root
    }

    // MARK: - Headerless chrome geometry

    /// True when the blank strip above the page is a window drag handle.
    var dragRegionAcceptsMouse: Bool {
        guard view.window != nil else { return false }
        view.layoutSubtreeIfNeeded()
        if tabBarVisible {
            // The tab strip itself is interactive; its empty area performs a
            // window drag in `DocumentTabBarView.mouseDown`.
            return tabBar.frame.height > 0
        }
        guard topDragView.frame.height > 0 else { return false }
        let point = NSPoint(x: topDragView.bounds.midX, y: topDragView.bounds.midY)
        return topDragView.mouseDownCanMoveWindow && topDragView.hitTest(point) === topDragView
    }

    // MARK: - Document tab strip

    /// Called by `DocumentWindowController.refreshTabChrome` for every window
    /// in the native tab group, so switching tabs always presents a tab strip
    /// with the same tab list and selection.
    func updateTabBar(windows: [NSWindow], selected: NSWindow, visible: Bool) {
        _ = view
        tabBarTabCount = windows.count
        tabBar.update(windows: windows, selected: selected)
        guard tabBarVisible != visible else {
            view.layoutSubtreeIfNeeded()
            return
        }
        tabBarVisible = visible
        tabBar.isHidden = !visible
        if visible {
            stackTopToSafeArea.isActive = false
            stackTopBelowTabBar.isActive = true
        } else {
            stackTopBelowTabBar.isActive = false
            stackTopToSafeArea.isActive = true
        }
        view.layoutSubtreeIfNeeded()
    }

    private func selectTab(_ window: NSWindow) {
        if let group = view.window?.tabGroup, group.windows.contains(window) {
            group.selectedWindow = window
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Distance from the window's top edge to the top of the tab strip. Must
    /// be 0 when tabs are shown: no blank band above the tabs.
    var tabBarTopInWindow: CGFloat {
        tabBarFrameInWindow.map { contentTopDistance(of: $0) } ?? -1
    }

    var tabBarLeftInWindow: CGFloat {
        tabBarFrameInWindow?.minX ?? -1
    }

    var tabBarWidthInWindow: CGFloat {
        tabBarFrameInWindow?.width ?? -1
    }

    var tabBarHeightInWindow: CGFloat {
        tabBarVisible ? tabBar.frame.height : 0
    }

    var tabBarTabsForTesting: [[String: Any]] {
        guard tabBarVisible, let content = view.window?.contentView else { return [] }
        view.layoutSubtreeIfNeeded()
        return tabBar.tabFramesForTesting.map { rect in
            let converted = tabBar.convert(rect, to: content)
            return [
                "top": content.bounds.height - converted.maxY,
                "height": converted.height,
                "left": converted.minX,
                "width": converted.width,
            ]
        }
    }

    var tabBarTabCountForTesting: Int { tabBarTabCount }

    /// Per-tab vertical centering metrics (title line box and close glyph)
    /// relative to the tab row's center. Used by the real-screen geometry
    /// check to prove the title is vertically centered, not top-aligned.
    var tabBarTitleMetricsForTesting: [[String: Any]] {
        guard tabBarVisible else { return [] }
        view.layoutSubtreeIfNeeded()
        return tabBar.titleMetricsForTesting
    }

    private var tabBarFrameInWindow: NSRect? {
        guard tabBarVisible, let window = view.window, let content = window.contentView else {
            return nil
        }
        view.layoutSubtreeIfNeeded()
        return tabBar.convert(tabBar.bounds, to: content)
    }

    private func contentTopDistance(of rectInContent: NSRect) -> CGFloat {
        guard let content = view.window?.contentView else { return -1 }
        return content.bounds.height - rectInContent.maxY
    }

    /// Distance from the window's top edge to the WebView. The page background
    /// exists above it, but no document text is allowed under the titlebar or
    /// the tab bar.
    var webViewTopInWindow: CGFloat {
        guard let window = view.window, let content = window.contentView else { return -1 }
        view.layoutSubtreeIfNeeded()
        let rect = webView.convert(webView.bounds, to: content)
        return content.bounds.height - rect.maxY
    }

    var findBarTopInWindow: CGFloat {
        guard let window = view.window, let content = window.contentView else { return -1 }
        view.layoutSubtreeIfNeeded()
        let rect = findBar.convert(findBar.bounds, to: content)
        return content.bounds.height - rect.maxY
    }

    var isFindVisible: Bool {
        !findBar.isHidden
    }

    func showFind() {
        if findBar.isHidden {
            findBar.isHidden = false
            view.layoutSubtreeIfNeeded()
        }
        findBar.focus()
        if !findBar.searchField.stringValue.isEmpty {
            findQuery = findBar.searchField.stringValue
            runFind(query: findQuery)
        }
    }

    func hideFind() {
        findBar.isHidden = true
        findBar.searchField.stringValue = ""
        findQuery = ""
        webView.clearFind()
        findBar.update(count: 0, current: 0, query: "")
        view.window?.makeFirstResponder(webView)
    }

    func findNext() {
        guard !findBar.isHidden else {
            showFind()
            return
        }
        guard !findQuery.isEmpty else {
            findBar.focus()
            return
        }
        webView.findNext(forward: true) { [weak self] result in
            self?.apply(result, query: self?.findQuery ?? "")
        }
    }

    func findPrevious() {
        guard !findBar.isHidden else {
            showFind()
            return
        }
        guard !findQuery.isEmpty else {
            findBar.focus()
            return
        }
        webView.findNext(forward: false) { [weak self] result in
            self?.apply(result, query: self?.findQuery ?? "")
        }
    }

    func refreshFindIfNeeded() {
        guard isFindVisible, !findQuery.isEmpty else { return }
        runFind(query: findQuery)
    }

    func setFindForTesting(_ query: String) {
        showFind()
        findBar.searchField.stringValue = query
        findQuery = query
        runFind(query: query)
    }

    private func runFind(query: String) {
        if query.isEmpty {
            webView.clearFind()
            findBar.update(count: 0, current: 0, query: "")
            return
        }
        webView.find(query) { [weak self] result in
            guard let self, self.findQuery == query else { return }
            self.apply(result, query: query)
        }
    }

    private func apply(_ result: FindResult, query: String) {
        findBar.update(count: result.count, current: result.current, query: query)
    }
}
