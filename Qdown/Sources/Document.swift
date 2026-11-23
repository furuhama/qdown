import AppKit

final class Document: NSDocument {

    private(set) var markdown: String = ""

    /// Watches the document path (and its parent directory) so on-disk edits,
    /// including atomic saves, update the displayed document.
    private var fileWatcher: DocumentFileWatcher?

    /// Number of times the document contents changed on disk and were applied.
    /// Exposed through the window controller for the verification harness.
    private(set) var liveReloadCount = 0

    override init() {
        super.init()
        hasUndoManager = false
    }

    deinit {
        fileWatcher?.stop()
    }

    override class var autosavesInPlace: Bool {
        false
    }

    /// Qdown shows the plain file name (including its extension) in the window
    /// title and in the window tab. NSDocument's default is the same, but being
    /// explicit keeps the behaviour stable across macOS versions.
    override var displayName: String? {
        get { fileURL?.lastPathComponent }
        set { }
    }

    override func makeWindowControllers() {
        let controller = DocumentWindowController(document: self)
        addWindowController(controller)
        // NSDocumentController's Finder / Apple Event open path creates the
        // window here and may not call NSWindowController.showWindow. Joining
        // the existing tab group at creation time covers every open path.
        if let window = controller.window {
            DocumentOpenCoordinator.attachToExistingWindow(window)
        }
        startWatchingFile()
    }

    override func read(from data: Data, ofType typeName: String) throws {
        markdown = TextDecoder.decode(data)
        // A manual `Document()` open sets fileURL before calling read. Starting
        // here also covers an edit that lands between read and window creation.
        startWatchingFile()
    }

    // MARK: - Live reload

    func startWatchingFile() {
        guard fileWatcher == nil, let fileURL else { return }
        let watcher = DocumentFileWatcher(fileURL: fileURL)
        watcher.onChange = { [weak self] data in
            self?.handleFileChange(data)
        }
        fileWatcher = watcher
        watcher.start()
    }

    func stopWatchingFile() {
        fileWatcher?.stop()
        fileWatcher = nil
    }

    private func handleFileChange(_ data: Data?) {
        // A missing path keeps the last display. The directory watcher still
        // runs, so recreating the same path reloads it.
        guard let data, let fileURL else { return }

        let text = TextDecoder.decode(data)
        // mtime-only changes (touch, metadata updates, an editor rewriting
        // identical bytes) must not re-render the page.
        guard text != markdown else { return }

        markdown = text
        liveReloadCount += 1
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let date = attributes[.modificationDate] as? Date {
            // Keep NSDocument's notion of the on-disk file in sync so it does
            // not treat this known change as an external edit.
            fileModificationDate = date
        }

        // Re-render through the normal marked -> viewer.html path. Focus is
        // untouched: no window is ordered front or made key here.
        for case let controller as DocumentWindowController in windowControllers {
            controller.applyLiveReload()
        }
    }

    override func close() {
        stopWatchingFile()
        super.close()
    }

    // Qdown is a viewer. These documents are intentionally never written back.
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        []
    }

    override var isEntireFileLoaded: Bool {
        true
    }
}

enum TextDecoder {
    /// Decodes a text document with a pragmatic fallback list. Markdown files are
    /// overwhelmingly UTF-8, but .txt files on Japanese systems can be Shift_JIS
    /// or EUC-JP, so those are tried before the lossy Latin-1 encodings.
    static func decode(_ data: Data) -> String {
        if data.isEmpty { return "" }

        // UTF-16 is only assumed when a BOM is present; otherwise arbitrary
        // Shift_JIS/EUC-JP byte pairs can decode as valid-looking UTF-16LE.
        if data.count >= 2 {
            let bytes = [UInt8](data.prefix(2))
            if bytes == [0xFF, 0xFE] {
                if let text = String(data: data, encoding: .utf16LittleEndian) {
                    return normalize(text)
                }
            } else if bytes == [0xFE, 0xFF] {
                if let text = String(data: data, encoding: .utf16BigEndian) {
                    return normalize(text)
                }
            }
        }

        let encodings: [String.Encoding] = [
            .utf8,
            .shiftJIS,
            .japaneseEUC,
            .windowsCP1252,
            .macOSRoman,
            .isoLatin1,
        ]

        for encoding in encodings {
            guard let text = String(data: data, encoding: encoding) else { continue }
            return normalize(text)
        }

        return normalize(String(decoding: data, as: UTF8.self))
    }

    private static func normalize(_ input: String) -> String {
        var text = input
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        return text
    }
}
