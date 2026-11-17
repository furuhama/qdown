import AppKit

enum DocumentOpenError: LocalizedError {
    case notAQdownDocument

    var errorDescription: String? {
        switch self {
        case .notAQdownDocument:
            return "The file could not be opened as a Qdown document."
        }
    }
}

/// Central place for opening Markdown documents.
///
/// Every entry point (Finder, the Open panel, drag and drop, and in-document
/// links) funnels through here so they all follow the same rule: when a Qdown
/// window is already available, the new document is added to that window's
/// native `NSWindow` tab group instead of opening a separate standalone window.
@MainActor
enum DocumentOpenCoordinator {

    /// When true (the production default), a document window joins an existing
    /// Qdown window as a tab as soon as it is shown. This covers opens that go
    /// through `NSDocumentController`'s own `odoc` Apple Event handling, which
    /// never reaches the app delegate's open callbacks.
    static var automaticallyTabsNewDocuments = true

    /// Opens several files in order. The first one joins `host` (or becomes a
    /// window when there is no host); each following one joins the same window.
    static func open(_ urls: [URL],
                     host: NSWindow? = nil,
                     completion: ((Result<[Document], Error>) -> Void)? = nil) {
        guard !urls.isEmpty else {
            completion?(.success([]))
            return
        }

        var documents: [Document] = []
        var target = host

        func openNext(_ index: Int) {
            guard index < urls.count else {
                completion?(.success(documents))
                return
            }
            open(urls[index], host: target) { result in
                switch result {
                case .success(let document):
                    documents.append(document)
                    if target == nil {
                        target = document.windowControllers.first?.window
                    }
                    openNext(index + 1)
                case .failure(let error):
                    completion?(.failure(error))
                }
            }
        }

        openNext(0)
    }

    /// Opens a single file, attaching its window to `host`'s tab group.
    static func open(_ url: URL,
                     host: NSWindow? = nil,
                     completion: ((Result<Document, Error>) -> Void)? = nil) {
        // Resolve the host before NSDocumentController can order a new window
        // in front and steal the "key window" slot.
        let target = host ?? preferredHostWindow()

        NSDocumentController.shared.openDocument(
            withContentsOf: url.standardizedFileURL,
            display: true
        ) { document, _, error in
            if let error {
                completion?(.failure(error))
                return
            }
            guard let document = document as? Document else {
                completion?(.failure(DocumentOpenError.notAQdownDocument))
                return
            }
            attach(document: document, to: target)
            completion?(.success(document))
        }
    }

    /// The window a newly opened document should join. Prefer the key window,
    /// then the main window, then the frontmost document window.
    static func preferredHostWindow(excluding excluded: NSWindow? = nil) -> NSWindow? {
        if let key = NSApp.keyWindow, key !== excluded, isDocumentWindow(key) { return key }
        if let main = NSApp.mainWindow, main !== excluded, isDocumentWindow(main) { return main }
        return NSApp.windows.first {
            isDocumentWindow($0) && $0 !== excluded && !$0.isMiniaturized
        }
    }

    /// Called when a document window is created or shown. If another Qdown
    /// window already exists, the new one joins its native tab group.
    static func attachToExistingWindow(_ window: NSWindow) {
        guard automaticallyTabsNewDocuments else { return }
        // Already part of a visible tab group.
        if let tabbed = window.tabbedWindows, tabbed.count > 1 { return }
        guard let host = preferredHostWindow(excluding: window), host !== window else { return }
        attach(window, to: host)
    }

    private static func isDocumentWindow(_ window: NSWindow) -> Bool {
        window.windowController is DocumentWindowController
    }

    private static func attach(document: Document, to host: NSWindow?) {
        guard let window = document.windowControllers.first?.window else { return }
        guard let host, host !== window else {
            window.makeKeyAndOrderFront(nil)
            return
        }
        attach(window, to: host)
    }

    private static func attach(_ window: NSWindow, to host: NSWindow) {
        makeTabbable(window)
        makeTabbable(host)

        // AppKit may already have tabbed the new window (for example when the
        // system preference is "Always"). Only add it when that did not happen.
        let alreadyGrouped = window.tabGroup != nil && window.tabGroup === host.tabGroup
        if !alreadyGrouped {
            host.addTabbedWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private static func makeTabbable(_ window: NSWindow) {
        if window.tabbingMode == .disallowed {
            window.tabbingMode = .preferred
        }
    }
}
