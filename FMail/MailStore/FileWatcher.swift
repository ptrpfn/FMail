import Foundation
import CoreServices

/// Wraps an `FSEventStream` rooted at `~/Library/Mail/V*/`. Coalesces with a
/// 2 s latency. Persists the last `FSEventStreamEventId` to UserDefaults so a
/// relaunch only sees changes since the previous session.
///
/// Filters at receive time: events for `*.emlx`, `*.partial.emlx`, and
/// `Envelope Index*` are forwarded. Everything else (BiomeStream churn,
/// interaction logs, etc.) is dropped.
final class FileWatcher: @unchecked Sendable {
    static let lastEventIdKey = "FMail.FSEventStream.lastEventId"

    private let path: String
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void
    private let queue: DispatchQueue
    private var coalescer: DispatchWorkItem?

    init(rootPath: String, onChange: @Sendable @escaping () -> Void) {
        self.path = rootPath
        self.onChange = onChange
        self.queue = DispatchQueue(label: "com.felixmatschke.FMail.fsevents", qos: .utility)
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }

        let pathsToWatch = [path] as CFArray
        let lastEvent: FSEventStreamEventId
        if let stored = UserDefaults.standard.object(forKey: Self.lastEventIdKey) as? UInt64 {
            lastEvent = FSEventStreamEventId(stored)
        } else {
            lastEvent = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let flags: UInt32 =
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagNoDefer) |
            UInt32(kFSEventStreamCreateFlagWatchRoot)

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, info, numEvents, eventPaths, _, eventIds) in
                guard let info else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                // Without kFSEventStreamCreateFlagUseCFTypes, eventPaths is a
                // C array of (const char *).
                let pathsBuf = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                var paths: [String] = []
                paths.reserveCapacity(numEvents)
                for i in 0..<numEvents {
                    if let cstr = pathsBuf[i] {
                        paths.append(String(cString: cstr))
                    }
                }
                let lastId = (0..<numEvents).map { eventIds[$0] }.max() ?? 0
                watcher.handle(paths: paths, lastEventId: lastId)
            },
            &context,
            pathsToWatch,
            lastEvent,
            2.0,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(s, queue)
        if FSEventStreamStart(s) {
            self.stream = s
        } else {
            FSEventStreamRelease(s)
        }
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        self.stream = nil
    }

    private func handle(paths: [String], lastEventId: FSEventStreamEventId) {
        // Filter to interesting paths.
        let interesting = paths.contains { p in
            p.hasSuffix(".emlx") ||
            p.hasSuffix(".partial.emlx") ||
            p.contains("/Envelope Index")
        }
        // Persist lastEventId regardless so we don't replay.
        UserDefaults.standard.set(UInt64(lastEventId), forKey: Self.lastEventIdKey)

        guard interesting else { return }

        // Debounce: wait 2 s of quiet, then fire.
        coalescer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        coalescer = work
        queue.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
}
