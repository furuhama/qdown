import AppKit

/// Qdown persists and restores its own tab session (`SessionStore`), so AppKit
/// must not also reopen the previous run's documents at launch. Without this,
/// a launch could restore every tab twice, and files the session store is meant
/// to skip (because they no longer exist) could still raise an error panel.
final class QdownDocumentController: NSDocumentController {

    /// State restoration asks the document controller to reopen documents
    /// through this method during launch. Qdown's session restore is the only
    /// reopen path, so decline it here.
    override func reopenDocument(for urlOrNil: URL?,
                                 withContentsOf contentsURL: URL,
                                 display displayDocument: Bool,
                                 completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        completionHandler(nil, false, nil)
    }

    /// AppKit may also try to restore individual document windows. Qdown's own
    /// `DocumentWindowController` windows are created from the saved session.
    override class func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier,
                                      state: NSCoder,
                                      completionHandler: @escaping (NSWindow?, Error?) -> Void) {
        completionHandler(nil, nil)
    }
}
