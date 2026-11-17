import AppKit

final class Document: NSDocument {

    private(set) var markdown: String = ""

    override init() {
        super.init()
        hasUndoManager = false
    }

    override class var autosavesInPlace: Bool {
        false
    }

    override func makeWindowControllers() {
        let controller = DocumentWindowController(document: self)
        addWindowController(controller)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        markdown = TextDecoder.decode(data)
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
