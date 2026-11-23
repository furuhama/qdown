import Darwin
import Foundation

/// Watches one document *path* and reports its current contents.
///
/// Editors often save atomically: they write a sibling file and `rename` it
/// over the document. A descriptor-only watcher loses the file at that point,
/// because the descriptor still refers to the unlinked original inode. This
/// watcher therefore keeps two kqueue sources open:
///
/// * the parent directory, which sees create/delete/rename events and survives
///   the document file being replaced; and
/// * the document file itself, which sees in-place writes.
///
/// Every event is debounced. After the debounce the path is resolved again,
/// its inode is compared with the watched descriptor, and the descriptor is
/// re-opened when it no longer matches (the atomic-save case). The callback is
/// then invoked with the file's data, or `nil` when the path does not exist.
/// Deletion is reported but never treated as a reason to clear the last
/// rendered document; the caller keeps showing the previous contents until the
/// same path is recreated.
final class DocumentFileWatcher {

    private let fileURL: URL
    private let directoryURL: URL
    private let debounceInterval: TimeInterval

    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var pendingScan: DispatchWorkItem?

    private(set) var isRunning = false

    /// Called on the main queue with the file's bytes, or `nil` when it is
    /// missing. A transient read failure also reports `nil`; the caller is
    /// expected to keep the last display in that case.
    var onChange: ((Data?) -> Void)?

    init(fileURL: URL, debounceInterval: TimeInterval = 0.25) {
        let standardized = fileURL.standardizedFileURL
        self.fileURL = standardized
        self.directoryURL = standardized.deletingLastPathComponent()
        self.debounceInterval = debounceInterval
    }

    deinit {
        stop()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startDirectorySource()
        refreshFileSource()
        scheduleScan()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pendingScan?.cancel()
        pendingScan = nil
        stopFileSource()
        directorySource?.cancel()
        directorySource = nil
        onChange = nil
    }

    // MARK: - Sources

    private var watchEvents: DispatchSource.FileSystemEvent {
        // NOTE_ATTRIB is deliberately not watched: reading a file can update
        // its access time, and watching metadata would turn every scan into
        // another event. An mtime-only change does not need to be observed
        // because the contents are compared before anything is re-rendered.
        [.write, .delete, .rename, .extend, .link, .revoke]
    }

    private func startDirectorySource() {
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: watchEvents,
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            // If the directory itself was renamed or removed the source is
            // finished; the document path cannot be watched from here anymore.
            if let flags = source?.data,
               !flags.intersection([.delete, .rename, .revoke]).isEmpty {
                self.directorySource?.cancel()
                self.directorySource = nil
            }
            self.scheduleScan()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        directorySource = source
        source.resume()
    }

    private func refreshFileSource() {
        var info = stat()
        guard stat(fileURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            stopFileSource()
            return
        }

        if let current = watchedIdentity(),
           current.inode == info.st_ino,
           current.device == info.st_dev {
            return
        }

        stopFileSource()

        let descriptor = open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: watchEvents,
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            if let flags = source?.data,
               !flags.intersection([.delete, .rename, .revoke]).isEmpty {
                // The descriptor refers to the old inode after an atomic save.
                // Drop it now; the scan below re-resolves the path and opens a
                // descriptor for the replacement file.
                self.stopFileSource()
            }
            self.scheduleScan()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        fileDescriptor = descriptor
        fileSource = source
        source.resume()
    }

    private func stopFileSource() {
        fileSource?.cancel()
        fileSource = nil
        fileDescriptor = -1
    }

    private func watchedIdentity() -> (inode: ino_t, device: dev_t)? {
        guard fileDescriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else { return nil }
        return (info.st_ino, info.st_dev)
    }

    // MARK: - Debounced rescan

    private func scheduleScan() {
        guard isRunning else { return }
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingScan = nil
            self.scan()
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func scan() {
        guard isRunning else { return }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else {
            stopFileSource()
            onChange?(nil)
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            refreshFileSource()
            onChange?(data)
        } catch {
            // Do not clear the display on a read error (for example a file that
            // is momentarily being written). The directory source will report
            // the next change at this path.
            stopFileSource()
            onChange?(nil)
        }
    }
}
