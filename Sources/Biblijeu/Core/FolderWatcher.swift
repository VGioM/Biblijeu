import CoreServices
import Foundation

/// Watches folder trees and reports changes, so a ROM copied in after launch
/// shows up on its own. Backed by FSEvents, which is recursive.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private var handler: (([String]) -> Void)?

    deinit { stopStream() }

    /// Begin watching `paths`; `handler` gets the paths that changed. Replaces
    /// any previous watch.
    func start(paths: [String], latency: TimeInterval = 2.5, handler: @escaping ([String]) -> Void) {
        stop()
        guard !paths.isEmpty else { return }
        self.handler = handler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let changed = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                as? [String] ?? []
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().handler?(changed)
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes)

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, flags) else { return }

        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() { stopStream() }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
