import AppKit

/// The ordered set of open document tabs plus the tab that was active, as
/// persisted for the next launch.
struct TabSession: Equatable {
    var paths: [String]
    var activeIndex: Int

    static let empty = TabSession(paths: [], activeIndex: 0)

    var isEmpty: Bool { paths.isEmpty }
}

/// Reads and writes `TabSession` in `UserDefaults`.
///
/// The test harness passes `QDOWNTEST_SESSION_SUITE` so verification never
/// touches the real user session. Any other harness mode that does not name a
/// suite is redirected to a scratch suite as well.
struct SessionStore {

    static let pathsKey = "QdownSessionPaths"
    static let activeIndexKey = "QdownSessionActiveIndex"

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        if let defaults {
            self.defaults = defaults
            return
        }

        let environment = ProcessInfo.processInfo.environment
        if let suite = environment["QDOWNTEST_SESSION_SUITE"], !suite.isEmpty,
           let scoped = UserDefaults(suiteName: suite) {
            self.defaults = scoped
            return
        }
        if environment["QDOWNTEST_MODE"] != nil,
           let scoped = UserDefaults(suiteName: "com.furuhama.qdown.sessiontest") {
            self.defaults = scoped
            return
        }
        self.defaults = .standard
    }

    /// Returns nil when nothing was ever saved. An explicitly empty session is
    /// also treated as nil because both mean "start empty".
    func load() -> TabSession? {
        guard let paths = defaults.stringArray(forKey: Self.pathsKey), !paths.isEmpty else {
            return nil
        }
        let storedIndex = defaults.integer(forKey: Self.activeIndexKey)
        return TabSession(paths: paths,
                          activeIndex: min(max(storedIndex, 0), paths.count - 1))
    }

    func save(_ session: TabSession) {
        guard !session.isEmpty else {
            clear()
            return
        }
        defaults.set(session.paths, forKey: Self.pathsKey)
        defaults.set(min(max(session.activeIndex, 0), session.paths.count - 1),
                     forKey: Self.activeIndexKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.pathsKey)
        defaults.removeObject(forKey: Self.activeIndexKey)
    }

    /// UserDefaults flushes on its own schedule. Forcing it here makes the
    /// session that is written during `applicationWillTerminate` visible to the
    /// next process immediately.
    func synchronize() {
        defaults.synchronize()
    }
}

/// Builds a `TabSession` from the live AppKit windows.
@MainActor
enum TabSessionSnapshot {

    /// All open document windows in tab order. The active tab's group comes
    /// first; other detached windows follow front-to-back. Each window keeps
    /// its own path, so a file opened twice appears twice.
    static func current() -> TabSession? {
        let windows = openDocumentWindows()
        guard !windows.isEmpty else { return nil }

        let active = activeDocumentWindow(among: windows)
        var ordered: [NSWindow] = []
        var seen = Set<ObjectIdentifier>()

        func appendGroup(containing window: NSWindow) {
            if let group = window.tabGroup {
                let identifier = ObjectIdentifier(group)
                guard seen.insert(identifier).inserted else { return }
                ordered.append(contentsOf: group.windows)
            } else {
                let identifier = ObjectIdentifier(window)
                guard seen.insert(identifier).inserted else { return }
                ordered.append(window)
            }
        }

        if let active {
            appendGroup(containing: active)
        }
        for window in windows {
            appendGroup(containing: window)
        }

        var paths: [String] = []
        var activeIndex = 0
        for window in ordered {
            guard let controller = window.windowController as? DocumentWindowController,
                  let url = controller.qdownDocument.fileURL else { continue }
            if window === active {
                activeIndex = paths.count
            }
            paths.append(url.standardizedFileURL.path)
        }

        guard !paths.isEmpty else { return nil }
        return TabSession(paths: paths, activeIndex: activeIndex)
    }

    @MainActor
    private static func openDocumentWindows() -> [NSWindow] {
        func isDocumentWindow(_ window: NSWindow) -> Bool {
            window.windowController is DocumentWindowController
                && (window.isVisible || window.isMiniaturized)
        }

        var windows: [NSWindow] = []
        var seen = Set<ObjectIdentifier>()
        for window in NSApp.orderedWindows where isDocumentWindow(window) {
            if seen.insert(ObjectIdentifier(window)).inserted {
                windows.append(window)
            }
        }
        for window in NSApp.windows where isDocumentWindow(window) {
            if seen.insert(ObjectIdentifier(window)).inserted {
                windows.append(window)
            }
        }
        return windows
    }

    @MainActor
    private static func activeDocumentWindow(among windows: [NSWindow]) -> NSWindow? {
        for candidate in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 })
        where windows.contains(where: { $0 === candidate }) {
            return candidate
        }
        // `selectedWindow` is the authoritative active tab and is updated even
        // when the app is not active. The key window only tells us which tab
        // group is frontmost.
        let anchor = [NSApp.keyWindow, NSApp.mainWindow]
            .compactMap { $0 }
            .first { candidate in windows.contains(where: { $0 === candidate }) }
            ?? windows.first
        if let selected = anchor?.tabGroup?.selectedWindow,
           windows.contains(where: { $0 === selected }) {
            return selected
        }
        return anchor
    }
}

/// Watches AppKit state and saves the session when tabs are opened, closed,
/// selected, reordered, or when the app is about to quit.
@MainActor
final class SessionRecorder: NSObject {

    static let shared = SessionRecorder()

    private let store = SessionStore()
    private var lastSaved: TabSession?
    private var pendingSave: DispatchWorkItem?
    private var started = false
    private var suspended = false
    private var terminating = false
    private var groupObservations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

    func start() {
        guard !started else { return }
        started = true
        lastSaved = store.load()
        refreshGroupObservations()

        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification,
                     NSWindow.didBecomeMainNotification,
                     NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification,
                     // Tab reordering and opening do not have a dedicated
                     // notification. A debounced update observer catches the
                     // resulting window update, and the state comparison below
                     // keeps it from writing when nothing changed.
                     NSWindow.didUpdateNotification] {
            center.addObserver(self,
                               selector: #selector(handleWindowEvent(_:)),
                               name: name,
                               object: nil)
        }
    }

    @objc private func handleWindowEvent(_ notification: Notification) {
        guard started, !suspended, !terminating else { return }
        if let window = notification.object as? NSWindow,
           !(window.windowController is DocumentWindowController) {
            return
        }
        refreshGroupObservations()
        scheduleSave()
    }

    /// Native tab groups notify KVO for both `windows` (open, close, and tab
    /// reorder) and `selectedWindow` (tab switch). Observing the group directly
    /// keeps saving independent of whether the app is active.
    private func refreshGroupObservations() {
        var liveGroups = Set<ObjectIdentifier>()

        for window in NSApp.windows where window.windowController is DocumentWindowController {
            guard let group = window.tabGroup else { continue }
            let identifier = ObjectIdentifier(group)
            liveGroups.insert(identifier)
            guard groupObservations[identifier] == nil else { continue }

            var observations: [NSKeyValueObservation] = []
            observations.append(group.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.scheduleSaveForGroupChange()
                }
            })
            observations.append(group.observe(\.windows, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.scheduleSaveForGroupChange()
                }
            })
            groupObservations[identifier] = observations
        }

        var deadGroups: [ObjectIdentifier] = []
        for (identifier, observations) in groupObservations where !liveGroups.contains(identifier) {
            observations.forEach { $0.invalidate() }
            deadGroups.append(identifier)
        }
        for identifier in deadGroups {
            groupObservations.removeValue(forKey: identifier)
        }
    }

    private func scheduleSaveForGroupChange() {
        guard started, !suspended, !terminating else { return }
        scheduleSave()
    }

    private func scheduleSave(after delay: TimeInterval = 0.35) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func saveNow() {
        guard started, !terminating else { return }
        refreshGroupObservations()

        guard let session = TabSessionSnapshot.current() else {
            if lastSaved != nil || store.load() != nil {
                store.save(.empty)
                lastSaved = nil
            }
            return
        }

        guard session != lastSaved else { return }
        store.save(session)
        lastSaved = session
    }

    /// Suppresses intermediate saves while a whole session is being reopened.
    /// Without this, each restored tab would overwrite the saved list with a
    /// shorter one until the next tab arrived.
    func beginRestoring() {
        suspended = true
        pendingSave?.cancel()
        pendingSave = nil
    }

    func endRestoring() {
        suspended = false
        saveNow()
    }

    func saveBeforeTermination() {
        guard started else { return }
        pendingSave?.cancel()
        pendingSave = nil
        // Save while `terminating` is still false; the flag then blocks the
        // window-close notifications AppKit sends during teardown from
        // overwriting the final session with an empty one.
        saveNow()
        terminating = true
        store.synchronize()
    }
}

enum SessionRestoreOutcome: Equatable {
    case skippedLaunchArguments
    case skippedExistingDocuments
    case noSavedSession
    case noExistingFiles
    case restored(count: Int)
}

/// Reopens a saved session, skipping paths that no longer exist.
@MainActor
enum SessionLaunchRestore {

    /// The number of file-looking command-line arguments. macOS hands direct
    /// CLI launches to NSDocumentController, so the presence of any such
    /// argument must suppress restoring the old session.
    static var commandLineFileArgumentCount: Int {
        CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.count
    }

    static func restoreOnLaunch(launchFileCount: Int,
                                existingDocumentCount: Int,
                                store: SessionStore = SessionStore(),
                                completion: ((SessionRestoreOutcome) -> Void)? = nil) {
        guard launchFileCount == 0 else {
            completion?(.skippedLaunchArguments)
            return
        }
        guard existingDocumentCount == 0 else {
            completion?(.skippedExistingDocuments)
            return
        }
        guard let session = store.load(), !session.isEmpty else {
            completion?(.noSavedSession)
            return
        }
        restore(session: session, store: store, completion: completion)
    }

    static func restore(session: TabSession,
                        store: SessionStore = SessionStore(),
                        completion: ((SessionRestoreOutcome) -> Void)? = nil) {
        let existing = session.paths.enumerated().compactMap { index, path -> (index: Int, url: URL)? in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return nil
            }
            return (index, url)
        }

        guard !existing.isEmpty else {
            completion?(.noExistingFiles)
            return
        }

        SessionRecorder.shared.beginRestoring()

        // Rebuild the saved tab order deterministically: every window joins
        // the group explicitly, appended after the previously opened tab.
        // Suppressing the implicit attachment keeps AppKit from choosing a
        // different insertion point while the app is still becoming active.
        DocumentOpenCoordinator.suppressesAutomaticTabAttachment = true
        let previousAutomaticTabbing = NSWindow.allowsAutomaticWindowTabbing
        NSWindow.allowsAutomaticWindowTabbing = false

        var lastWindow: NSWindow?
        var opened: [(originalIndex: Int, window: NSWindow)] = []
        var seenPaths = Set<String>()

        func finish() {
            NSWindow.allowsAutomaticWindowTabbing = previousAutomaticTabbing
            DocumentOpenCoordinator.suppressesAutomaticTabAttachment = false
            selectActiveWindow(opened: opened, savedActiveIndex: session.activeIndex)
            SessionRecorder.shared.endRestoring()
            completion?(.restored(count: opened.count))
        }

        func openNext(_ cursor: Int) {
            guard cursor < existing.count else {
                finish()
                return
            }
            let entry = existing[cursor]

            let isDuplicate = !seenPaths.insert(entry.url.path).inserted
            let handler: (Result<Document, Error>) -> Void = { result in
                if case .success(let document) = result,
                   let window = document.windowControllers.first?.window {
                    lastWindow = window
                    opened.append((entry.index, window))
                }
                openNext(cursor + 1)
            }

            if isDuplicate {
                DocumentOpenCoordinator.openDuplicate(entry.url,
                                                      host: lastWindow,
                                                      completion: handler)
            } else {
                DocumentOpenCoordinator.open(entry.url,
                                             host: lastWindow,
                                             completion: handler)
            }
        }

        openNext(0)
    }

    /// Picks the saved active tab. If that file is gone, the next surviving tab
    /// to its right becomes active; otherwise the last surviving tab does.
    private static func selectActiveWindow(opened: [(originalIndex: Int, window: NSWindow)],
                                           savedActiveIndex: Int) {
        guard let target = opened.first(where: { $0.originalIndex == savedActiveIndex })
            ?? opened.first(where: { $0.originalIndex > savedActiveIndex })
            ?? opened.last else {
            return
        }
        if let group = target.window.tabGroup {
            group.selectedWindow = target.window
        }
        target.window.makeKeyAndOrderFront(nil)
    }
}
