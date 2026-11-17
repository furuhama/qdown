import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private weak var recentMenu: NSMenu?
    private var renderTestStarted = false
    private var isShowingOpenPanel = false

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Native window tabbing is the core of Qdown's multi-document UI.
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if RenderTestRunner.isTestMode {
            if !renderTestStarted {
                renderTestStarted = true
                RenderTestRunner.run()
            }
            return
        }

        // Touch the shared controller early so document handling is ready before
        // LaunchServices delivers an open event.
        _ = NSDocumentController.shared

        // A plain launch has no document. Wait briefly for a possible open event
        // (double-click / "Open With"), then offer the open panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self else { return }
            guard !RenderTestRunner.isTestMode else { return }
            if NSDocumentController.shared.documents.isEmpty,
               NSApp.windows.filter({ $0.isVisible }).isEmpty {
                self.presentOpenPanel(preferredHost: nil)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            presentOpenPanel(preferredHost: nil)
        }
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Command-line file arguments are for the headless harness, not for
        // opening extra documents. The live-tabs harness deliberately accepts
        // real LaunchServices open events so Finder double-click is covered.
        guard !RenderTestRunner.isTestMode || RenderTestRunner.acceptsOpenEvents else { return }
        openFromEvent(urls)
    }

    /// Legacy LaunchServices callback. NSDocumentController usually consumes
    /// `odoc` events itself, but some launch paths can reach these delegate
    /// methods; routing them through the coordinator keeps the tab rule.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard !RenderTestRunner.isTestMode || RenderTestRunner.acceptsOpenEvents else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }
        openFromEvent(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard !RenderTestRunner.isTestMode || RenderTestRunner.acceptsOpenEvents else { return false }
        openFromEvent([URL(fileURLWithPath: filename)])
        return true
    }

    private func openFromEvent(_ urls: [URL]) {
        // Capture the existing window before NSDocumentController opens the
        // first new window, so all files land in one tab group.
        let host = DocumentOpenCoordinator.preferredHostWindow()
        DocumentOpenCoordinator.open(urls, host: host) { [weak self] result in
            if case .failure(let error) = result { self?.presentError(error) }
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Qdown could not open the document."
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - Menu

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // ---- Application ----
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Qdown")
        appMenuItem.submenu = appMenu

        let about = NSMenuItem(title: "About Qdown", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(NSMenuItem.separator())

        let defaultApp = NSMenuItem(title: "Set Qdown as Default Markdown Viewer…",
                                    action: #selector(setAsDefaultMarkdownViewer(_:)),
                                    keyEquivalent: "")
        defaultApp.target = self
        appMenu.addItem(defaultApp)
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(withTitle: "Hide Qdown", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Qdown", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // ---- File ----
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu

        let open = NSMenuItem(title: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)

        let newTab = NSMenuItem(title: "New Tab…", action: #selector(newTab(_:)), keyEquivalent: "t")
        newTab.target = self
        fileMenu.addItem(newTab)

        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = self
        recentItem.submenu = recent
        recentMenu = recent
        fileMenu.addItem(recentItem)
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // ---- Edit ----
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())

        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findItem.submenu = findMenu
        editMenu.addItem(findItem)

        let find = NSMenuItem(title: "Find…",
                              action: #selector(DocumentWindowController.performFindPanelAction(_:)),
                              keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        findMenu.addItem(find)

        let findNext = NSMenuItem(title: "Find Next",
                                  action: #selector(DocumentWindowController.performFindPanelAction(_:)),
                                  keyEquivalent: "g")
        findNext.tag = Int(NSFindPanelAction.next.rawValue)
        findMenu.addItem(findNext)

        let findPrev = NSMenuItem(title: "Find Previous",
                                  action: #selector(DocumentWindowController.performFindPanelAction(_:)),
                                  keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        findPrev.tag = Int(NSFindPanelAction.previous.rawValue)
        findMenu.addItem(findPrev)

        // ---- View ----
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        let zoomIn = NSMenuItem(title: "Zoom In",
                                action: #selector(DocumentWindowController.zoomIn(_:)),
                                keyEquivalent: "+")
        viewMenu.addItem(zoomIn)
        // Alternate ⌘= for keyboards where "+" needs Shift.
        let zoomInAlternate = NSMenuItem(title: "Zoom In",
                                         action: #selector(DocumentWindowController.zoomIn(_:)),
                                         keyEquivalent: "=")
        zoomInAlternate.isAlternate = true
        zoomInAlternate.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(zoomInAlternate)

        viewMenu.addItem(NSMenuItem(title: "Zoom Out",
                                    action: #selector(DocumentWindowController.zoomOut(_:)),
                                    keyEquivalent: "-"))
        viewMenu.addItem(NSMenuItem(title: "Actual Size",
                                    action: #selector(DocumentWindowController.actualSize(_:)),
                                    keyEquivalent: "0"))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen",
                         action: #selector(NSWindow.toggleFullScreen(_:)),
                         keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]

        // ---- Window ----
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu

        // Standard macOS window-tab commands. Targets stay nil so AppKit
        // routes them through the responder chain (the key window).
        windowMenu.addItem(withTitle: "Show Tab Bar",
                           action: #selector(NSWindow.toggleTabBar(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(withTitle: "Show All Tabs",
                           action: #selector(NSWindow.toggleTabOverview(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(withTitle: "Move Tab to New Window",
                           action: #selector(NSWindow.moveTabToNewWindow(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(withTitle: "Merge All Windows",
                           action: #selector(NSWindow.mergeAllWindows(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())

        let nextTab = NSMenuItem(title: "Select Next Tab",
                                 action: #selector(NSWindow.selectNextTab(_:)),
                                 keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        windowMenu.addItem(nextTab)
        let previousTab = NSMenuItem(title: "Select Previous Tab",
                                     action: #selector(NSWindow.selectPreviousTab(_:)),
                                     keyEquivalent: "\t")
        previousTab.keyEquivalentModifierMask = [.control, .shift]
        windowMenu.addItem(previousTab)
        windowMenu.addItem(NSMenuItem.separator())

        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    // MARK: - Actions

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openDocument(_ sender: Any?) {
        presentOpenPanel(preferredHost: DocumentOpenCoordinator.preferredHostWindow())
    }

    @objc private func newTab(_ sender: Any?) {
        presentOpenPanel(preferredHost: DocumentOpenCoordinator.preferredHostWindow())
    }

    @objc private func openRecent(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let url = item.representedObject as? URL else { return }
        let host = DocumentOpenCoordinator.preferredHostWindow()
        DocumentOpenCoordinator.open(url, host: host) { [weak self] result in
            if case .failure(let error) = result { self?.presentError(error) }
        }
    }

    /// Qdown owns the Open panel instead of delegating to NSDocumentController
    /// so every selected file goes through DocumentOpenCoordinator and joins
    /// the existing window's tab group.
    private func presentOpenPanel(preferredHost: NSWindow?) {
        guard !isShowingOpenPanel else { return }
        isShowingOpenPanel = true

        let panel = NSOpenPanel()
        panel.title = "Open Markdown"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType(importedAs: "net.daringfireball.markdown"),
            .plainText,
        ]

        // `preferredHost` is captured now: the open panel itself becomes the
        // key window while it is on screen.
        let host = preferredHost
        panel.begin { [weak self] response in
            guard let self else { return }
            self.isShowingOpenPanel = false
            guard response == .OK else { return }
            DocumentOpenCoordinator.open(panel.urls, host: host) { [weak self] result in
                if case .failure(let error) = result { self?.presentError(error) }
            }
        }
    }

    @objc private func setAsDefaultMarkdownViewer(_ sender: Any?) {
        let contentType = UTType(importedAs: "net.daringfireball.markdown")
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: contentType) { error in
            DispatchQueue.main.async {
                let alert = NSAlert()
                if let error {
                    alert.alertStyle = .warning
                    alert.messageText = "Could not set Qdown as the default Markdown viewer."
                    alert.informativeText = error.localizedDescription
                } else {
                    alert.alertStyle = .informational
                    alert.messageText = "Qdown is now the default Markdown viewer."
                    alert.informativeText = "Finder will open .md and .markdown files in Qdown."
                }
                alert.runModal()
            }
        }
    }

    // MARK: - Recent documents

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()

        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            let empty = NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for url in urls {
                let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                item.toolTip = url.path
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let clear = NSMenuItem(title: "Clear Menu",
                               action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                               keyEquivalent: "")
        clear.target = NSDocumentController.shared
        menu.addItem(clear)
    }
}
