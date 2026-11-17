import AppKit
import WebKit

struct FindResult {
    let count: Int
    let current: Int

    static let none = FindResult(count: 0, current: 0)
}

final class MarkdownWebView: WKWebView, WKNavigationDelegate, WKScriptMessageHandler {

    private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?

        init(target: WKScriptMessageHandler?) {
            self.target = target
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            target?.userContentController(userContentController, didReceive: message)
        }
    }

    private let resourceDirectory: URL
    private let documentDirectory: URL
    private let schemeHandler: LocalSchemeHandler
    private let messageProxy: WeakMessageHandler

    private var isViewerLoaded = false
    private var pendingMarkdown: String?
    private var pendingBaseDirectory: URL?

    var onHeadings: (([[String: Any]]) -> Void)?
    var onOpenLink: ((String) -> Void)?
    var onRenderDone: (([String: Any]) -> Void)?
    var onLog: ((String) -> Void)?
    var onViewerReady: (() -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    private(set) var lastRenderStats: [String: Any] = [:]

    var requestedResourcePaths: [String] {
        schemeHandler.requestedPaths
    }

    var isViewerReady: Bool {
        isViewerLoaded
    }

    // MARK: - Init

    init(documentDirectory: URL, resourceDirectory: URL) {
        self.documentDirectory = documentDirectory.standardizedFileURL
        self.resourceDirectory = resourceDirectory.standardizedFileURL
        let handler = LocalSchemeHandler(documentDirectory: documentDirectory, resourceDirectory: resourceDirectory)
        self.schemeHandler = handler

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(handler, forURLScheme: "qdown")

        let proxy = WeakMessageHandler(target: nil)
        self.messageProxy = proxy
        configuration.userContentController.add(proxy, name: "qdown")

        // Runs before any page script, so CSP violations and script-load errors
        // are still visible to the native side for diagnostics.
        let earlyDiagnostics = """
        (function () {
          function send(message) {
            try {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.qdown) {
                window.webkit.messageHandlers.qdown.postMessage({ type: 'log', message: message });
              }
            } catch (error) { /* ignore */ }
          }
          window.addEventListener('error', function (event) {
            var target = event.target;
            if (target && target !== window && target.tagName) {
              send('resource error: ' + target.tagName + ' ' + (target.src || target.href || ''));
            } else {
              send('error: ' + (event.message || 'unknown') + ' @ ' + (event.filename || '') + ':' + (event.lineno || 0));
            }
          }, true);
          document.addEventListener('securitypolicyviolation', function (event) {
            send('CSP violation: ' + event.violatedDirective + ' blocked ' + (event.blockedURI || '') + ' on ' + (event.sourceFile || '') + ':' + (event.lineNumber || 0));
          });
        })();
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: earlyDiagnostics, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        super.init(frame: .zero, configuration: configuration)

        proxy.target = self
        navigationDelegate = self
        allowsMagnification = false
        allowsBackForwardNavigationGestures = false
        registerForDraggedTypes([.fileURL])

        NetworkBlocker.shared.prepare { [weak self] list in
            guard let self, let list else { return }
            self.configuration.userContentController.add(list)
        }

        loadViewer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Loading & rendering

    private func loadViewer() {
        guard let url = URL(string: "qdown://app/viewer.html") else { return }
        load(URLRequest(url: url))
    }

    func render(markdown: String, baseDirectory: URL) {
        pendingMarkdown = markdown
        pendingBaseDirectory = baseDirectory
        if isViewerLoaded {
            flushPendingRender()
        }
    }

    private func flushPendingRender() {
        guard isViewerLoaded,
              let markdown = pendingMarkdown,
              let baseDirectory = pendingBaseDirectory else { return }
        pendingMarkdown = nil
        pendingBaseDirectory = nil

        let baseHref = Self.baseHref(for: baseDirectory)
        callAsyncJavaScript(
            "return await window.qdown.render(markdown, baseHref);",
            arguments: ["markdown": markdown, "baseHref": baseHref],
            in: nil,
            in: .page
        ) { [weak self] result in
            if case .failure(let error) = result {
                self?.onLog?("render: \(error.localizedDescription)")
            }
        }
    }

    static func baseHref(for directory: URL) -> String {
        let path = directory.standardizedFileURL.path
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        let encoded = components
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return encoded.isEmpty ? "qdown://doc/" : "qdown://doc/\(encoded)/"
    }

    // MARK: - JS bridge

    func find(_ query: String, completion: @escaping (FindResult) -> Void) {
        guard isViewerLoaded else {
            completion(.none)
            return
        }
        callAsyncJavaScript(
            "return window.qdown.find(query);",
            arguments: ["query": query],
            in: nil,
            in: .page
        ) { result in
            completion(Self.parseFindResult(result))
        }
    }

    func findNext(forward: Bool, completion: @escaping (FindResult) -> Void) {
        guard isViewerLoaded else {
            completion(.none)
            return
        }
        callAsyncJavaScript(
            "return window.qdown.findNext(forward);",
            arguments: ["forward": forward],
            in: nil,
            in: .page
        ) { result in
            completion(Self.parseFindResult(result))
        }
    }

    func clearFind() {
        evaluateJavaScript("window.qdown.clearFind();", completionHandler: nil)
    }

    func setFindFallback(_ enabled: Bool) {
        evaluateJavaScript("window.qdown.setFindFallback(\(enabled ? "true" : "false"));", completionHandler: nil)
    }

    func scrollToHeading(id: String) {
        callAsyncJavaScript(
            "window.qdown.scrollToHeading(id);",
            arguments: ["id": id],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    func debugJSON(completion: @escaping (String) -> Void) {
        evaluateJavaScript("JSON.stringify(window.qdown.debugStats())") { value, _ in
            completion((value as? String) ?? "{}")
        }
    }

    private static func parseFindResult(_ result: Result<Any, Error>) -> FindResult {
        guard case .success(let value) = result, let dictionary = value as? [String: Any] else {
            return .none
        }
        let count = (dictionary["count"] as? NSNumber)?.intValue
            ?? (dictionary["count"] as? Int)
            ?? 0
        let current = (dictionary["current"] as? NSNumber)?.intValue
            ?? (dictionary["current"] as? Int)
            ?? 0
        return FindResult(count: count, current: current)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            isViewerLoaded = true
            onViewerReady?()
            flushPendingRender()

        case "headings":
            if let headings = body["headings"] as? [[String: Any]] {
                onHeadings?(headings)
            }

        case "openLink":
            if let href = body["href"] as? String {
                onOpenLink?(href)
            }

        case "renderDone":
            if let stats = body["stats"] as? [String: Any] {
                lastRenderStats = stats
                onRenderDone?(stats)
            }

        case "log", "error":
            if let text = body["message"] as? String {
                onLog?(text)
            }

        default:
            break
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if url.scheme?.lowercased() == "qdown" {
            if url.host?.lowercased() == "app" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
            return
        }

        if navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" || scheme == "mailto" {
                NSWorkspace.shared.open(url)
            } else if url.isFileURL {
                NSWorkspace.shared.open(url)
            }
            return
        }

        // Nothing else (remote redirects, subresource navigations, etc.) may load.
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" || scheme == "mailto" || url.isFileURL {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The JS bridge normally posts "ready" from DOMContentLoaded. This is a
        // safety net in case that message is lost.
        if !isViewerLoaded {
            isViewerLoaded = true
            onViewerReady?()
            flushPendingRender()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onLog?("navigation: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onLog?("provisional navigation: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onLog?("The WebContent process terminated; reloading.")
        isViewerLoaded = false
        loadViewer()
    }

    private func droppedFileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if droppedFileURLs(from: sender).isEmpty {
            return super.draggingEntered(sender)
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if droppedFileURLs(from: sender).isEmpty {
            return super.draggingUpdated(sender)
        }
        return .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if droppedFileURLs(from: sender).isEmpty {
            return super.prepareForDragOperation(sender)
        }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(from: sender)
        if urls.isEmpty {
            return super.performDragOperation(sender)
        }
        onDropFiles?(urls)
        return true
    }
}
