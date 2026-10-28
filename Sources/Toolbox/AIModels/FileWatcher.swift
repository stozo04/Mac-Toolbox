import CoreServices
import Foundation

/// Tells when anything inside a set of folders changes (FSEvents), including files inside folders that already exist.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "toolbox.filewatcher", qos: .utility)
    let paths: [String]
    let latency: TimeInterval

    init(paths: [String], latency: TimeInterval = 1, onChange: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard stream == nil, !paths.isEmpty else { return stream != nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let made = FSEventStreamCreate(nil, Self.callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return false }
        FSEventStreamSetDispatchQueue(made, queue)
        guard FSEventStreamStart(made) else {
            FSEventStreamInvalidate(made)
            FSEventStreamRelease(made)
            return false
        }
        stream = made
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
        let list = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
        watcher.onChange(Array(list.prefix(count)))
    }
}
