import Foundation

/// Resolves the href of a clicked link without touching the network.
enum LinkRouter {

    enum Destination: Equatable {
        case external(URL)
        case localFile(URL)
        case unsupported
    }

    static func resolve(_ rawHref: String, relativeTo baseDirectory: URL) -> Destination {
        let href = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty else { return .unsupported }

        // In-page anchors never leave the document.
        if href.hasPrefix("#") { return .unsupported }

        if let url = URL(string: href), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https", "mailto":
                return .external(url)
            case "file":
                return .localFile(url.standardizedFileURL)
            default:
                // javascript:, data:, and anything else are not navigable.
                return .unsupported
            }
        }

        // Relative path. Drop query/fragment, then resolve against the document's
        // directory. `..` is allowed on purpose: repository docs commonly link to
        // sibling directories.
        var path = href
        if let hash = path.firstIndex(of: "#") {
            path = String(path[..<hash])
        }
        if let question = path.firstIndex(of: "?") {
            path = String(path[..<question])
        }
        guard !path.isEmpty else { return .unsupported }

        let decoded = path.removingPercentEncoding ?? path
        let url: URL
        if decoded.hasPrefix("/") {
            url = URL(fileURLWithPath: decoded)
        } else {
            url = URL(fileURLWithPath: decoded, relativeTo: baseDirectory)
        }
        return .localFile(url.standardizedFileURL)
    }
}
