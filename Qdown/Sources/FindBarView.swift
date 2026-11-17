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
    private let topDragView = WindowDragView()

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

        NSLayoutConstraint.activate([
            // The page background reaches the window's top edge, while the
            // find bar and WebView start below the titlebar (or the native tab
            // bar, whose height AppKit folds into the safe area). The strip
            // above the stack is a drag handle for moving the window.
            topDragView.topAnchor.constraint(equalTo: root.topAnchor),
            topDragView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topDragView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topDragView.bottomAnchor.constraint(equalTo: stack.topAnchor),

            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            findBar.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            webView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])

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
        guard topDragView.frame.height > 0 else { return false }
        let point = NSPoint(x: topDragView.bounds.midX, y: topDragView.bounds.midY)
        return topDragView.mouseDownCanMoveWindow && topDragView.hitTest(point) === topDragView
    }

    /// Distance from the window's top edge to the WebView. With tabs AppKit's
    /// native tab bar (and the safe area it contributes) sits above it; with a
    /// single document the 28pt headerless strip does.
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


/// An otherwise empty view whose drag moves the window. Standard AppKit
/// `mouseDownCanMoveWindow` behaviour keeps the chrome headerless while still
/// letting the user reposition the window by its top strip.
final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        return self
    }
}
