import CoreServices
import Foundation

/// One FSEvents stream per library folder (file-level events, 1 s latency).
/// Reports *that* a folder changed; the caller rescans it and reconciles against the index.
final class FolderWatcher: @unchecked Sendable {
    enum Change: Sendable {
        /// Something inside the folder changed.
        case contents
        /// The folder itself was moved, renamed, deleted or its volume unmounted.
        case root
    }

    private let lock = NSLock()
    private var streams: [UUID: FSEventStreamRef] = [:]
    private let queue = DispatchQueue(label: "app.teinte.folder-watcher", qos: .utility)
    private let onChange: @Sendable (UUID, Change) -> Void

    init(onChange: @escaping @Sendable (UUID, Change) -> Void) {
        self.onChange = onChange
    }

    deinit {
        for id in lock.withLock({ Array(streams.keys) }) { unwatch(id) }
    }

    func watch(_ id: UUID, url: URL) {
        unwatch(id)
        // FSEvents reports real paths (/private/var/…); resolvingSymlinksInPath would strip /private.
        let root = realpath(url.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? url.path
        let box = Box(id: id, root: root, onChange: onChange)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil, release: { info in info.map { Unmanaged<Box>.fromOpaque($0).release() } },
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let paths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var change: Change?
            for i in 0..<count {
                let f = Int(flags[i])
                if f & (kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount) != 0 {
                    change = .root
                    break
                }
                if f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped
                        | kFSEventStreamEventFlagUserDropped) != 0 || box.matters(String(cString: paths[i])) {
                    change = .contents
                }
            }
            if let change { box.onChange(box.id, change) }
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        lock.withLock { streams[id] = stream }
    }

    func unwatch(_ id: UUID) {
        guard let stream = lock.withLock({ streams.removeValue(forKey: id) }) else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    var watched: Set<UUID> { lock.withLock { Set(streams.keys) } }

    private final class Box: Sendable {
        let id: UUID
        let root: String
        let onChange: @Sendable (UUID, Change) -> Void

        init(id: UUID, root: String, onChange: @escaping @Sendable (UUID, Change) -> Void) {
            self.id = id; self.root = root; self.onChange = onChange
        }

        /// Hidden files and folders are skipped by the scanner, so changes to them don't need a rescan
        /// (Finder rewrites .DS_Store just by opening a folder). Nor do changes to the root folder's
        /// own metadata: what happens inside it is reported with the inner paths.
        func matters(_ path: String) -> Bool {
            guard path.hasPrefix(root) else { return true }
            let components = path.dropFirst(root.count).split(separator: "/")
            return !components.isEmpty && !components.contains { $0.hasPrefix(".") }
        }
    }
}
