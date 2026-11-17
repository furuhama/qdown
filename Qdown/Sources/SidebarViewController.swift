import AppKit

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    final class HeadingNode: NSObject {
        let id: String
        let level: Int
        let text: String
        var children: [HeadingNode] = []

        init(id: String, level: Int, text: String) {
            self.id = id
            self.level = level
            self.text = text
        }
    }

    private static let sidebarColor = NSColor(srgbRed: 0.929, green: 0.929, blue: 0.961, alpha: 1.0)
    private static let purpleDeep = NSColor(srgbRed: 0.439, green: 0.337, blue: 0.592, alpha: 1.0)
    private static let purple = NSColor(srgbRed: 0.478, green: 0.243, blue: 0.616, alpha: 1.0)
    private static let bodyColor = NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "見出しがありません")
    private var roots: [HeadingNode] = []

    private(set) var headingCount = 0
    var onSelectHeading: ((String) -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 600))
        root.wantsLayer = true
        root.layer?.backgroundColor = Self.sidebarColor.cgColor

        let header = NSView(frame: .zero)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = Self.sidebarColor.cgColor

        let title = NSTextField(labelWithString: "見出し")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        title.textColor = Self.purpleDeep
        header.addSubview(title)

        let separator = NSView(frame: .zero)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(srgbRed: 0.769, green: 0.718, blue: 0.843, alpha: 0.7).cgColor
        header.addSubview(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HeadingColumn"))
        column.title = "見出し"
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowHeight = 24
        outlineView.intercellSpacing = NSSize(width: 0, height: 1)
        outlineView.indentationPerLevel = 13
        outlineView.indentationMarkerFollowsCell = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.backgroundColor = Self.sidebarColor
        outlineView.gridStyleMask = []
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.focusRingType = .none
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.selectionHighlightStyle = .regular
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.frame = NSRect(x: 0, y: 0, width: 230, height: 0)
        outlineView.autoresizingMask = [.width]

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Self.sidebarColor
        scrollView.borderType = .noBorder

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = NSColor(srgbRed: 0.467, green: 0.467, blue: 0.467, alpha: 1.0)
        emptyLabel.alignment = .center

        root.addSubview(header)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),

            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 8),
        ])

        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentSize.width
        if width > 0, outlineView.frame.width != width {
            outlineView.frame.size.width = width
        }
    }

    func update(headings: [[String: Any]]) {
        _ = view
        var newRoots: [HeadingNode] = []
        var stack: [HeadingNode] = []
        var total = 0

        for entry in headings {
            guard let id = entry["id"] as? String else { continue }
            let text = (entry["text"] as? String) ?? ""
            let level = (entry["level"] as? NSNumber)?.intValue
                ?? (entry["level"] as? Int)
                ?? 1
            let node = HeadingNode(id: id, level: min(max(level, 1), 6), text: text)

            while let last = stack.last, last.level >= node.level {
                stack.removeLast()
            }
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                newRoots.append(node)
            }
            stack.append(node)
            total += 1
        }

        roots = newRoots
        headingCount = total
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        emptyLabel.isHidden = total > 0
    }

    // MARK: - Outline view

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? HeadingNode {
            return node.children.count
        }
        return roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? HeadingNode {
            return node.children[index]
        }
        return roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? HeadingNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        24
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        HeadingRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? HeadingNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("HeadingCell")

        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.maximumNumberOfLines = 1
            textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = node.text
        cell.textField?.font = font(for: node.level)
        cell.textField?.textColor = color(for: node.level)
        cell.toolTip = node.text
        return cell
    }

    private func font(for level: Int) -> NSFont {
        switch level {
        case 1: return NSFont.systemFont(ofSize: 13, weight: .semibold)
        case 2: return NSFont.systemFont(ofSize: 12.5, weight: .medium)
        case 3: return NSFont.systemFont(ofSize: 12, weight: .regular)
        default: return NSFont.systemFont(ofSize: 11.5, weight: .regular)
        }
    }

    private func color(for level: Int) -> NSColor {
        switch level {
        case 1, 2: return Self.purpleDeep
        case 3: return Self.purple
        case 6: return NSColor(srgbRed: 0.467, green: 0.467, blue: 0.467, alpha: 1.0)
        default: return Self.bodyColor
        }
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? HeadingNode else { return }
        onSelectHeading?(node.id)
    }

    /// Selects the row and performs the same callback as a click. Used by the
    /// headless smoke test to verify the native sidebar → WebView path.
    func clickHeadingForTesting(id: String) -> Bool {
        _ = view
        guard let node = findNode(id: id, in: roots) else { return false }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return false }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        onSelectHeading?(node.id)
        return true
    }

    private func findNode(id: String, in nodes: [HeadingNode]) -> HeadingNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = findNode(id: id, in: node.children) { return found }
        }
        return nil
    }
}

final class HeadingRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 5, dy: 1)
        NSColor(srgbRed: 0.769, green: 0.718, blue: 0.843, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        .normal
    }
}
