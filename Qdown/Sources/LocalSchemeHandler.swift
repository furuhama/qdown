import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves both the app's viewer assets and local images from the document's
/// directory through a private `qdown://` scheme. The WebView never gets file://
/// access, and the only accepted hosts are `app` and `doc`.
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {

    struct Payload {
        let data: Data
        let mimeType: String
    }

    enum HandlerError: LocalizedError {
        case notFound(String)
        case forbidden(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let path): return "Qdown could not read \(path)."
            case .forbidden(let path): return "Qdown refused to read \(path)."
            }
        }
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic", "heif", "avif", "ico",
    ]

    private let resourceDirectory: URL
    private let documentDirectory: URL
    private let lock = NSLock()
    private var activeTasks = Set<ObjectIdentifier>()

    /// Requested qdown:// paths. Used by the render-test harness to prove that
    /// only local resources were requested.
    private(set) var requestedPaths: [String] = []

    init(documentDirectory: URL, resourceDirectory: URL) {
        self.documentDirectory = documentDirectory.standardizedFileURL
        self.resourceDirectory = resourceDirectory.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.lock()
        activeTasks.insert(identifier)
        lock.unlock()

        defer {
            lock.lock()
            activeTasks.remove(identifier)
            lock.unlock()
        }

        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, error: HandlerError.notFound("(missing URL)"))
            return
        }
        requestedPaths.append(url.absoluteString)

        do {
            let payload = try payload(for: url)
            guard isActive(identifier) else { return }
            let response = URLResponse(
                url: url,
                mimeType: payload.mimeType,
                expectedContentLength: payload.data.count,
                textEncodingName: payload.mimeType.hasPrefix("text/") ? "utf-8" : nil
            )
            urlSchemeTask.didReceive(response)
            guard isActive(identifier) else { return }
            urlSchemeTask.didReceive(payload.data)
            guard isActive(identifier) else { return }
            urlSchemeTask.didFinish()
        } catch {
            fail(urlSchemeTask, error: error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        activeTasks.remove(ObjectIdentifier(urlSchemeTask as AnyObject))
        lock.unlock()
    }

    private func isActive(_ identifier: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeTasks.contains(identifier)
    }

    private func fail(_ task: WKURLSchemeTask, error: Error) {
        guard isActive(ObjectIdentifier(task as AnyObject)) else { return }
        task.didFailWithError(error)
    }

    private func payload(for url: URL) throws -> Payload {
        guard let host = url.host?.lowercased() else {
            throw HandlerError.notFound(url.absoluteString)
        }
        let path = url.path(percentEncoded: false)

        switch host {
        case "app":
            var relative = path
            while relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { throw HandlerError.notFound(path) }

            let candidate = resourceDirectory.appendingPathComponent(relative).standardizedFileURL
            let resolved = candidate.resolvingSymlinksInPath()
            let root = resourceDirectory.resolvingSymlinksInPath()
            guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
                throw HandlerError.forbidden(path)
            }
            return try readFile(at: resolved)

        case "doc":
            guard path.hasPrefix("/") else { throw HandlerError.forbidden(path) }
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            let ext = candidate.pathExtension.lowercased()
            guard Self.imageExtensions.contains(ext) else {
                throw HandlerError.forbidden("Only local images can be loaded through qdown://doc.")
            }
            return try readFile(at: candidate)

        default:
            throw HandlerError.forbidden(host)
        }
    }

    private func readFile(at url: URL) throws -> Payload {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else {
            throw HandlerError.notFound(url.path)
        }
        if let size = values?.fileSize, size > 200 * 1024 * 1024 {
            throw HandlerError.forbidden("The file is too large to display: \(url.lastPathComponent)")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return Payload(data: data, mimeType: Self.mimeType(for: url))
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()),
           let mime = type.preferredMIMEType {
            return mime
        }
        switch url.pathExtension.lowercased() {
        case "css": return "text/css"
        case "js", "mjs": return "text/javascript"
        case "html", "htm": return "text/html"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}

/// Compiles a WebKit content blocker that rejects every network scheme. This is
/// a belt-and-braces layer: the page's CSP and the private qdown:// scheme are
/// the primary guarantees.
final class NetworkBlocker {

    static let shared = NetworkBlocker()

    private var ruleList: WKContentRuleList?
    private var waiters: [(WKContentRuleList?) -> Void] = []
    private var started = false

    private init() {}

    func prepare(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let ruleList {
            completion(ruleList)
            return
        }
        waiters.append(completion)
        guard !started else { return }
        started = true

        let json = """
        [
          {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}
        ]
        """

        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("QdownContentRuleLists", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        let store: WKContentRuleListStore?
        if let custom = WKContentRuleListStore(url: storeURL) {
            store = custom
        } else {
            store = WKContentRuleListStore.default()
        }
        guard let store else {
            let pending = self.waiters
            self.waiters.removeAll()
            pending.forEach { $0(nil) }
            return
        }
        store.compileContentRuleList(
            forIdentifier: "QdownBlockNetworkV1",
            encodedContentRuleList: json
        ) { [weak self] list, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ruleList = list
                let pending = self.waiters
                self.waiters.removeAll()
                pending.forEach { $0(list) }
            }
        }
    }
}
