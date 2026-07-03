import CoreServices
import Foundation

/// Watches adapter log root directories with FSEvents and reports coarse-grained
/// "something may have changed" signals. Callers should debounce before rescanning.
final class UsageDirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.vibeusage.directory-watcher")
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var paths: [String] = []

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stopLocked()
    }

    func update(paths: [String]) {
        lock.lock()
        defer { lock.unlock() }
        guard paths != self.paths else { return }
        self.paths = paths
        restartStreamLocked()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    private func restartStreamLocked() {
        stopLocked()
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopLocked() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func handleChange() {
        onChange()
    }

    private static let eventCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<UsageDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        watcher.handleChange()
    }
}
