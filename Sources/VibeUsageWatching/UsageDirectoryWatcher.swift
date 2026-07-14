import CoreServices
import Foundation
import os

/// Watches adapter log root directories with FSEvents and reports changed paths.
/// Callers should debounce before rescanning and may map paths to source filters.
final class UsageDirectoryWatcher: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.vibeusage", category: "DirectoryWatcher")

    private let queue = DispatchQueue(label: "com.vibeusage.directory-watcher")
    private let onChange: @Sendable ([String]) -> Void
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    private(set) var isWatching = false

    init(onChange: @escaping @Sendable ([String]) -> Void) {
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
        guard !paths.isEmpty else {
            isWatching = false
            return
        }

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
            isWatching = false
            Self.logger.error(
                "Failed to create FSEventStream for paths: \(self.paths.joined(separator: ", "), privacy: .public). Falling back to periodic refresh only."
            )
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        isWatching = true
    }

    private func stopLocked() {
        guard let stream else {
            isWatching = false
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        isWatching = false
    }

    fileprivate func handleChange(paths: [String]) {
        onChange(paths)
    }

    private static let eventCallback: FSEventStreamCallback = {
        _,
        info,
        numEvents,
        eventPaths,
        _,
        _ in
        guard let info else { return }
        let watcher = Unmanaged<UsageDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        watcher.handleChange(paths: extractChangedPaths(from: eventPaths, count: numEvents))
    }
}

private func extractChangedPaths(from eventPaths: UnsafeMutableRawPointer?, count: Int) -> [String] {
    guard count > 0, let eventPaths else { return [] }
    let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    return (0..<count).compactMap { index in
        guard let value = CFArrayGetValueAtIndex(cfArray, index) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
}
